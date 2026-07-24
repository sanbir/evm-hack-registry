// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27528-h-38-magnetar-contract-has-no-approval-checking-code4rena-ta.sol";

contract MagnetarNoApprovalTest is Test {
    function test_attacker_drains_victim_via_magnetar() public {
        Exploit exp = new Exploit();
        exp.run();
        assertEq(exp.stolen(), exp.VICTIM_DEPOSIT(), "full drain");
        assertEq(exp.token().balanceOf(address(exp)), exp.VICTIM_DEPOSIT());
        assertEq(exp.yieldBox().balanceOf(address(exp.victim())), 0);
    }
}
