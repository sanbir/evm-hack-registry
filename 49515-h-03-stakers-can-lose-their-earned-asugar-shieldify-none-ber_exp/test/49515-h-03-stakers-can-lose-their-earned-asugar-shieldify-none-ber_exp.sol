// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./49515-h-03-stakers-can-lose-their-earned-asugar-shieldify-none-ber.sol";

contract ASugarWipeTest is Test {
    uint256 internal constant LOST = 1000 ether;

    function test_exploit_secondStakeWipesPendingASugar() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.wiped(), LOST, "wiped");
        assertEq(e.claimed(), 0, "claimed");
        assertEq(e.kept(), LOST, "kept");
        assertEq(e.sugar().balanceOf(e.FORFEIT()), LOST, "forfeit");
        assertEq(e.sugar().balanceOf(address(e)), LOST, "staker from control only");
    }

    function test_control_secondStakeMintsThePendingWindow() public {
        Exploit e = new Exploit();
        // the control path is inside run(); this test only re-checks the preserved amount
        e.run();
        assertEq(e.sugar().balanceOf(address(e)), LOST, "staker kept the 10 day accrual");
        assertEq(e.claimed(), 0, "buggy claim paid nothing");
    }
}
