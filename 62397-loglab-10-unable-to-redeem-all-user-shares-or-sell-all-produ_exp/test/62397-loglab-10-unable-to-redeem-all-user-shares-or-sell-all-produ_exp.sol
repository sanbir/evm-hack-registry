// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, SpotManager, HedgeManager, BasisStrategy} from
    "./62397-loglab-10-unable-to-redeem-all-user-shares-or-sell-all-produ.sol";

contract Finding62397Test is Test {
    function test_exploit_close_all_buys_back_900() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.asset().balanceOf(address(e.spot())), 900 ether, "spot bought 900");
        assertEq(e.asset().balanceOf(e.strategy().redeemerOf()), 100 ether, "redeemer got 100");
        assertEq(e.short().balanceOf(e.SINK()), 900 ether, "900 locked");
        assertEq(e.strategy().clampedSize(), 10_000 ether, "sentinel clamped");
        assertEq(e.strategy().assetsReverted(), 900 ether, "reverted");
        assertEq(e.strategy().paidToRedeemer(), 100 ether, "paid");
    }

    function test_control_max_decrease_pays_the_full_1000() public {
        Asset asset = new Asset();
        SpotManager spot = new SpotManager();
        HedgeManager hedge = new HedgeManager();
        BasisStrategy strategy = new BasisStrategy(asset, spot, hedge);
        strategy.runClose(type(uint256).max, 1_000 ether);
        assertEq(asset.balanceOf(strategy.redeemerOf()), 1_000 ether, "redeemer got 1000");
        assertEq(asset.balanceOf(address(spot)), 0, "spot bought nothing");
        assertEq(strategy.assetsReverted(), 0, "no buyback");
        assertEq(strategy.clampedSize(), type(uint256).max, "sentinel kept");
        assertEq(strategy.usedSentinel(), 1, "close-all branch");
        assertEq(strategy.paidToRedeemer(), 1_000 ether, "full pay");
    }
}
