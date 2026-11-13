// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    DelegationFixed,
    Exploit,
    Token
} from "./61538-reward-distribution-enables-front-running-attacks-and-reward.sol";

contract Finding61538Test is Test {
    function test_exploit_b_takes_750_of_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paidB(), 750 ether, "front-runner share");
        assertEq(e.paidA(), 250 ether, "long-term vault share");
        assertEq(e.reward().balanceOf(address(e)), 750 ether);
        assertEq(e.reward().balanceOf(address(e.vaultA())), 250 ether);
    }

    function test_control_new_delegation_earns_nothing() public {
        Token reward = new Token("Reward", "RWD", 18);
        DelegationFixed delegation = new DelegationFixed(reward);
        address vaultA = address(0xA11CE);
        delegation.delegate(vaultA, 100 ether);
        delegation.lock();
        delegation.delegate(address(this), 300 ether);
        reward.mint(address(delegation), 1000 ether);
        delegation.distributeTo(vaultA);
        assertEq(reward.balanceOf(vaultA), 1000 ether, "A did not receive N");
        assertEq(reward.balanceOf(address(this)), 0, "B was paid");
    }
}
