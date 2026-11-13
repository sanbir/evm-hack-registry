// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LP, MFD, Victim} from "./53446-malicious-user-can-flood-a-user-s-staked-locks-array-and-pre.sol";

contract Finding53446Test is Test {
    function test_exploit_flooded_locks_make_withdraw_exceed_the_cap() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.oneLockGas(), e.GAS_CAP(), "one lock fits in the cap");
        assertTrue(e.floodedReverted(), "flooded withdraw reverted");
        assertEq(e.locked(), e.PRINCIPAL() + e.FLOOD(), "principal plus dust still in MFD");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim received nothing");
        assertEq(e.mfd().lockCount(address(e.victim())), e.FLOOD() + 1, "array was flooded");
    }

    function test_control_length_cap_lets_the_same_gas_withdraw() public {
        LP token = new LP();
        MFD fixedMfd = new MFD(token, 1);
        Victim victim = new Victim();
        token.mint(address(this), 100 ether + 4);
        token.approve(address(fixedMfd), type(uint256).max);
        fixedMfd.stake(address(victim), 100 ether);

        vm.expectRevert(bytes("cap"));
        fixedMfd.stake(address(victim), 1);

        victim.pull(address(fixedMfd), 400_000);

        assertEq(token.balanceOf(address(victim)), 100 ether, "victim recovered the stake");
        assertEq(token.balanceOf(address(fixedMfd)), 0, "MFD empty");
        assertEq(fixedMfd.lockCount(address(victim)), 1, "no flood");
    }
}
