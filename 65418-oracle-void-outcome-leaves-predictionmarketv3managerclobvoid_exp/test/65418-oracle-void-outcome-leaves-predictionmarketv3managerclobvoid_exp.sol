// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PredictionMarketV3ManagerCLOB,
    PredictionMarketV3ManagerCLOBFixed,
    ConditionalTokens,
    MockMarketOracle,
    MiniToken,
    IERC20Like
} from "./65418-oracle-void-outcome-leaves-predictionmarketv3managerclobvoid.sol";

contract OracleVoidLocksCollateralTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant HOLDER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant DEPOSIT = 1e18;

    // ── HARM: oracle-voided market freezes all position collateral ────────────
    function test_exploit_oracleVoidFreezesCollateral() public {
        Exploit e = new Exploit();
        e.run();

        // redeemVoided reverted for the holder (0 + 0 != 1e18).
        assertTrue(e.redeemReverted(), "redeemVoided should revert for oracle-voided market");

        // The full 1e18 deposit is frozen inside ConditionalTokens with no path out.
        MiniToken collateral = MiniToken(e.collateralAddr());
        assertEq(
            collateral.balanceOf(e.conditionalTokensAddr()),
            DEPOSIT,
            "collateral frozen in ConditionalTokens"
        );
        assertEq(e.lockedCollateral(), DEPOSIT, "locked magnitude");

        // Marker records the frozen magnitude at the SINK (lock/DoS marker).
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), DEPOSIT, "LOCKED-COLL marker minted to SINK");

        // The manager confirms the market is resolved-as-void but voidedPayouts is empty:
        // getVoidedPayouts returns (0, 0) precisely because resolveMarket never set it.
        PredictionMarketV3ManagerCLOB manager = PredictionMarketV3ManagerCLOB(e.managerAddr());
        (uint256 p0, uint256 p1) = manager.getVoidedPayouts(e.marketId());
        assertEq(p0, 0, "outcome0 payout never set");
        assertEq(p1, 0, "outcome1 payout never set");
    }

    // ── NEGATIVE CONTROL #1: correct admin void path lets the holder redeem ───
    // Same buggy manager + ConditionalTokens, but the void goes through
    // adminVoidMarket (which sets voidedPayouts = [0.5e18, 0.5e18]). Redemption
    // now succeeds and returns the full collateral — proving the harm is caused
    // specifically by resolveMarket's failure to set voidedPayouts, not by
    // redeemVoided itself.
    function test_control_adminVoidMarket_allowsRedeem() public {
        MiniToken collateral = new MiniToken("Collateral", "COLL");
        PredictionMarketV3ManagerCLOB manager = new PredictionMarketV3ManagerCLOB();
        MockMarketOracle oracle = new MockMarketOracle();
        ConditionalTokens ct = new ConditionalTokens(address(manager));

        uint256 marketId = manager.createMarket(address(oracle), IERC20Like(address(collateral)));

        // holder deposits collateral into ConditionalTokens
        vm.startPrank(HOLDER);
        collateral.mint(HOLDER, DEPOSIT);
        collateral.approve(address(ct), DEPOSIT);
        ct.splitPosition(marketId, DEPOSIT);
        vm.stopPrank();

        // correct void: payouts sum to 1e18
        manager.adminVoidMarket(marketId, 0.5e18, 0.5e18);

        assertEq(collateral.balanceOf(address(ct)), DEPOSIT, "collateral held pre-redeem");

        vm.prank(HOLDER);
        ct.redeemVoided(marketId);

        // holder recovered the full deposit; nothing frozen.
        assertEq(collateral.balanceOf(HOLDER), DEPOSIT, "holder recovers full collateral");
        assertEq(collateral.balanceOf(address(ct)), 0, "no collateral left frozen");
    }

    // ── NEGATIVE CONTROL #2: fixed manager rejects the -1 oracle outcome ──────
    // The recommended mitigation (resolveMarket rejects outcome == -1) makes the
    // resolve revert, so no market can ever end up resolved-but-unvoidable.
    function test_control_fixedManager_rejectsMinusOne() public {
        MiniToken collateral = new MiniToken("Collateral", "COLL");
        PredictionMarketV3ManagerCLOBFixed manager = new PredictionMarketV3ManagerCLOBFixed();
        MockMarketOracle oracle = new MockMarketOracle();
        oracle.setResult(-1, true);

        uint256 marketId = manager.createMarket(address(oracle), IERC20Like(address(collateral)));

        vm.expectRevert(bytes("oracle: invalid outcome"));
        manager.resolveMarket(marketId);
    }
}
