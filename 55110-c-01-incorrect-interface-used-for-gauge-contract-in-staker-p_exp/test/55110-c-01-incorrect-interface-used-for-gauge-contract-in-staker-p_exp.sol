// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Collateral,
    Exploit,
    IGauge,
    RewardVault,
    Staker
} from "./55110-c-01-incorrect-interface-used-for-gauge-contract-in-staker-p.sol";

contract Finding55110Test is Test {
    function test_exploit_wrong_selector_leaves_5_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 5 ether, "5 stuck");
        assertEq(e.paid(), 0, "user received nothing");
        assertFalse(e.withdrew(), "withdraw reverted");
    }

    function test_control_two_arg_selector_pays_5() public {
        Collateral token = new Collateral();
        RewardVault vault = new RewardVault(token);
        Staker staker = new Staker(token, IGauge(address(vault)));
        token.mint(address(staker), 5 ether);
        token.mint(address(vault), 5 ether);
        staker.deposit(5 ether);
        staker.withdrawFixed(address(this));
        assertEq(token.balanceOf(address(this)), 10 ether, "user received the 5 stake plus the 5 reward");
        assertEq(token.balanceOf(address(staker)), 0, "staker empty");
    }
}
