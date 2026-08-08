// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DESK / HMX — Incorrect Margin Calculation Due to Inconsistent Realized
    and Unrealized Balances  (Tripathi / Cantina HMX Jan 2025, finding #53108)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: LiquidationHandler computes total margin by applying the
    settlement-token collateral factor ONLY to a positive unsettled PnL, while
    AssetService.getSubaccountTotalMargin already applies the CF to the
    realized settlement-token balance. Two economically identical positions
    that differ only in their realized/unrealized ratio therefore report
    different margins. A position can be incorrectly liquidated (or incorrectly
    spared) solely because of how much PnL has been realized.

    Vulnerable calculation preserved verbatim with @> VULN marker.
    Recommended fix: aggregate realized + unrealized before applying CF. */

uint256 constant BPS = 10_000;

/// @dev Minimal AssetService surface used by LiquidationHandler.
contract AssetService {
    mapping(address => int256) public realizedSettlement; // e18-scaled settlement token
    mapping(address => uint256) public collateralFactors; // BPS, for settlement token
    address public settlementToken;

    constructor(address st) {
        settlementToken = st;
        collateralFactors[st] = 9000; // 0.9 CF as in the finding PoC
    }

    function setCollateralFactor(address token, uint256 factorBps) external {
        collateralFactors[token] = factorBps;
    }

    /// @dev Adjust realized settlement balance (mirrors adjustCollateral for USDC).
    function adjustCollateral(address subaccount, int256 deltaE18) external {
        realizedSettlement[subaccount] += deltaE18;
    }

    /// @dev Realized margin already applies the collateral factor.
    function getSubaccountTotalMargin(address subaccount) external view returns (int256) {
        int256 bal = realizedSettlement[subaccount];
        int256 cf = int256(collateralFactors[settlementToken]);
        // Realized always multiplied by CF (positive or negative).
        return bal * cf / int256(BPS);
    }

    function getSubaccountPendingBorrowingFee(address) external pure returns (int256) {
        return 0;
    }
}

/// @dev Minimal PerpService surface.
contract PerpService {
    mapping(address => int256) public unrealizedPnL; // e18

    function setUnrealized(address subaccount, int256 upnl) external {
        unrealizedPnL[subaccount] = upnl;
    }

    function getSubaccountTotalUnrealizedPNLAndFundingFee(address subaccount)
        external
        view
        returns (int256 totalUPnLE18, int256 totalFundingFeeE18)
    {
        return (unrealizedPnL[subaccount], 0);
    }
}

/// @notice Reduced LiquidationHandler — preserves the blamed margin calculation.
contract LiquidationHandler {
    AssetService public immutable assetService;
    PerpService public immutable perpService;
    address public immutable settlementToken;
    int256 public mmrE18; // minimum margin requirement

    // Exposed for the PoC assertions
    int256 public lastMargin;
    bool public lastWouldLiquidate;

    constructor(AssetService a, PerpService p, address st, int256 mmr) {
        assetService = a;
        perpService = p;
        settlementToken = st;
        mmrE18 = mmr;
    }

    /// @dev Faithful reduction of LiquidationHandler._executeAction margin math
    ///      (LiquidationHandler.sol ~L77). Returns total margin with unsettled;
    ///      also records whether the account would be liquidated (margin < MMR).
    function evaluateLiquidation(address subaccount) external returns (int256 totalMarginWithUnsettledE18) {
        int256 _borrowingFeeE18 = assetService.getSubaccountPendingBorrowingFee(subaccount);
        (int256 _totalUPnLE18, int256 _totalFundingFeeE18) =
            perpService.getSubaccountTotalUnrealizedPNLAndFundingFee(subaccount);
        int256 _unsettledE18 = _totalUPnLE18 - _totalFundingFeeE18 - _borrowingFeeE18;

        // Apply collateral factor if unsettled balance is positive
        if (_unsettledE18 > 0) {
            _unsettledE18 =
                _unsettledE18 * int256(assetService.collateralFactors(settlementToken)) / int256(BPS);
        }
        // FIX: aggregate realized + unrealized BEFORE applying the CF once.
        totalMarginWithUnsettledE18 = assetService.getSubaccountTotalMargin(subaccount) + _unsettledE18; // @> VULN: CF only on +unsettled; realized CF'd separately

        lastMargin = totalMarginWithUnsettledE18;
        lastWouldLiquidate = totalMarginWithUnsettledE18 < mmrE18;
    }
}

/// @dev Stand-in for settlement token address only (no token ops needed).
contract SettlementToken {}

/// @notice Orchestrator: demonstrates two economically identical positions
///         reporting different margins; one incorrectly liquidatable.
contract Exploit {
    SettlementToken public st; // CREATE nonce 1
    AssetService public assetService; // CREATE nonce 2
    PerpService public perpService; // CREATE nonce 3
    LiquidationHandler public handler; // CREATE nonce 4

    address public constant ALICE = address(0xA11CE);

    // Economic position always nets to +100e18 settlement units.
    // Scenario 1: realized +600, unrealized -500 → margin = 600*0.9 + (-500) = 40
    // Scenario 2: realized +500, unrealized -400 → margin = 500*0.9 + (-400) = 50
    // MMR set to 45 so scenario 1 is incorrectly liquidatable while scenario 2 is not.
    int256 public constant MMR = 45 ether;

    int256 public marginScenario1;
    int256 public marginScenario2;
    bool public liquidatableScenario1;
    bool public liquidatableScenario2;

    constructor() {
        st = new SettlementToken(); // nonce 1
        assetService = new AssetService(address(st)); // nonce 2
        perpService = new PerpService(); // nonce 3
        handler = new LiquidationHandler(assetService, perpService, address(st), MMR); // nonce 4
    }

    function run() external {
        // === Scenario 1: -500 unrealized + 600 realized ===
        assetService.adjustCollateral(ALICE, 600 ether);
        perpService.setUnrealized(ALICE, -500 ether);
        handler.evaluateLiquidation(ALICE);
        marginScenario1 = handler.lastMargin();
        liquidatableScenario1 = handler.lastWouldLiquidate();

        // Reset Alice's realized to 0 then set scenario 2 state
        assetService.adjustCollateral(ALICE, -600 ether);

        // === Scenario 2: realize 100 of the unrealized loss ===
        // realized +500, unrealized -400 (same net economic position: +100)
        assetService.adjustCollateral(ALICE, 500 ether);
        perpService.setUnrealized(ALICE, -400 ether);
        handler.evaluateLiquidation(ALICE);
        marginScenario2 = handler.lastMargin();
        liquidatableScenario2 = handler.lastWouldLiquidate();

        // HARM: identical economic positions, different margins
        require(marginScenario1 != marginScenario2, "margins should differ due to bug");
        require(marginScenario1 == 40 ether, "scenario1 expected 40");
        require(marginScenario2 == 50 ether, "scenario2 expected 50");

        // With MMR=45, scenario 1 is incorrectly liquidated while scenario 2 is not
        // — pure artifact of the realized/unrealized split, not true risk.
        require(liquidatableScenario1, "scenario1 should be liquidatable under buggy math");
        require(!liquidatableScenario2, "scenario2 should NOT be liquidatable");
        require(marginScenario1 < MMR && marginScenario2 >= MMR, "incorrect liquidation boundary");
    }
}
