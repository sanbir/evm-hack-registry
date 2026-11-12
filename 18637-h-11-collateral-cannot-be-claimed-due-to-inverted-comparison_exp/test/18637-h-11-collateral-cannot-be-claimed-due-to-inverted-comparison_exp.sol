// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    MarketUtils
} from "./18637-h-11-collateral-cannot-be-claimed-due-to-inverted-comparison.sol";

contract Finding18637Test is Test {
    address internal constant USER = 0x2222222222222222222222222222222222222222;

    function test_inverted_comparison_locks_claimable_collateral() public {
        Exploit e = new Exploit();
        e.run();

        MarketUtils market = e.market();
        console2.log("credited", e.credited());
        console2.log("adjusted", e.adjustedBefore());
        console2.log("claimed before", e.claimedBefore());
        console2.log("claim reverted", e.claimReverted());
        console2.log("stuck", e.stuck());
        console2.log("user received", e.userReceived());

        assertEq(e.credited(), 1000 ether, "credited 1000");
        assertEq(e.adjustedBefore(), 1000 ether, "adjusted is the full 1000");
        assertEq(e.claimedBefore(), 0, "claimed starts at 0");
        assertEq(e.claimReverted(), true, "claim reverted");
        assertEq(e.revertSelector(), e.expectedSelector(), "CollateralAlreadyClaimed");
        assertEq(e.stuck(), 1000 ether, "1000 collateral stuck in the market");
        assertEq(e.userReceived(), 0, "user received nothing");
        assertEq(e.token().balanceOf(address(market)), 1000 ether, "market balance");
        assertEq(e.token().balanceOf(USER), 0, "user balance");
        assertEq(market.escrowed(), 1000 ether, "escrow recorded");
    }

    function test_control_right_comparison_pays_the_user() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control paid", e.controlPaid());
        console2.log("control left", e.controlLeft());
        console2.log("control second reverted", e.controlSecondReverted());

        assertEq(e.controlPaid(), 1000 ether, "control pays the user 1000");
        assertEq(e.controlLeft(), 0, "fixed market is empty");
        assertEq(e.token().balanceOf(USER), 1000 ether, "user token balance");
        assertEq(e.controlSecondReverted(), true, "a second claim reverts once paid");
    }
}
