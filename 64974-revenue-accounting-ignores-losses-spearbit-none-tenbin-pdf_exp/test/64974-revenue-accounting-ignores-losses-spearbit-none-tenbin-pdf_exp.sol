// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    CollateralManager,
    CollateralManagerFixed,
    MiniToken,
    MiniVault,
    IERC4626
} from "./64974-revenue-accounting-ignores-losses-spearbit-none-tenbin-pdf.sol";

contract RevenueAccountingIgnoresLossesTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_lossesIgnored_drainsPrincipalAsFakeRevenue() public {
        Exploit e = new Exploit();
        e.run();

        // Real drain: the collector was paid the full stale 20 units of "revenue",
        // and the manager's collateral balance dropped by exactly 20.
        assertEq(e.collectorReceived(), 20 ether, "collector received full stale 20");
        assertEq(e.managerBalBefore() - e.managerBalAfter(), 20 ether, "manager drained by 20");

        // True net yield across the gain-then-loss was only 5 (100 -> 120 -> 105),
        // so 15 of the payout is principal drained as fake revenue.
        assertEq(e.principalDrained(), 15 ether, "15 principal drained beyond the 5 true yield");

        // The 15-unit principal drain is recorded on the MARKER token at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 15 ether, "marker records 15 principal drained at SINK");
        assertEq(e.sinkMarkerBalance(), 15 ether, "exposed sink marker matches");

        // Negative control ran inside run(): the loss-adjusting manager blocked it.
        assertTrue(e.fixedReverted(), "fixed variant blocked the over-withdrawal");

        // Manager still holds 980; honest accounting (pay only the 5 real yield) would
        // have left 995 — the 15 gap is under-collateralization from mislabeled principal.
        MiniToken collateral = MiniToken(e.collateralAddr());
        assertEq(collateral.balanceOf(e.managerAddr()), 980 ether, "manager left short by 15 vs honest 995");
    }

    function test_control_fixedManager_subtractsLoss_blocksOverWithdrawal() public {
        // Rebuild the identical scenario against the FIXED (loss-adjusting) manager.
        MiniToken collateral = new MiniToken("Collateral", "COL");
        MiniVault vault = new MiniVault();
        CollateralManagerFixed manager = new CollateralManagerFixed();

        vault.setTotalAssets(100 ether);
        manager.registerCollateral(address(collateral), IERC4626(address(vault)));
        collateral.mint(address(manager), 1000 ether);

        // Gain to 120: books +20 into pendingRevenue, high-water mark -> 120.
        vault.setTotalAssets(120 ether);
        manager.withdrawRevenue(address(collateral), 0);

        // Loss to 105: the fix subtracts the 15 loss -> pendingRevenue = 5.
        vault.setTotalAssets(105 ether);
        vm.expectRevert(CollateralManagerFixed.ExceedsPendingRevenue.selector);
        manager.withdrawRevenue(address(collateral), 20 ether);

        // Only the true net yield (5) is withdrawable; principal is preserved.
        manager.withdrawRevenue(address(collateral), 5 ether);
        assertEq(collateral.balanceOf(address(this)), 5 ether, "only the 5 true yield withdrawable");
        assertEq(collateral.balanceOf(address(manager)), 995 ether, "principal fully preserved under the fix");
    }
}
