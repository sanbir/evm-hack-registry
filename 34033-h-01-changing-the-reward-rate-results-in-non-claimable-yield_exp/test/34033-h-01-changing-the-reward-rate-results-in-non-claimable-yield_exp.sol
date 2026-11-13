// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./34033-h-01-changing-the-reward-rate-results-in-non-claimable-yield.sol";

contract FindingTest is Test {
    function test_attack() public {
        vm.warp(10 days);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.accruedBefore(), 500 ether);
        assertEq(e.accruedAfter(), 0);
        assertEq(e.validatorBal(), 0);
        assertEq(e.token().balanceOf(address(e.vault())), 500 ether);
    }

    function test_control() public {
        vm.warp(10 days);
        Exploit e = new Exploit();
        e.runControl();
    }
}
