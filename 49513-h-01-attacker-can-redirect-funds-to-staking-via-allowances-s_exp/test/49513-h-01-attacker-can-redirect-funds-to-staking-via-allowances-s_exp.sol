// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Holder, MockToken, StakingKoFixed} from "./49513-h-01-attacker-can-redirect-funds-to-staking-via-allowances-s.sol";

contract AllowanceRedirectTest is Test {
    uint256 internal constant AMOUNT = 1000 ether;

    function test_exploit_attackerStakesTheVictimsAllowance() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), AMOUNT, "taken");
        assertEq(e.victimLeft(), AMOUNT, "left after the pull of one 1000");
        assertEq(e.token().balanceOf(address(e.staking())), AMOUNT, "staking");
        assertTrue(e.controlBlocked(), "blocked");
        assertEq(e.controlLeft(), AMOUNT, "control left before the owner stake");
        assertEq(e.token().balanceOf(address(e.control())), AMOUNT, "owner stake");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim emptied by the owner stake");
    }

    function test_control_onlyTheOwnerCanStake() public {
        MockToken token = new MockToken();
        Holder victim = new Holder();
        StakingKoFixed staking = new StakingKoFixed(address(token));
        token.mint(address(victim), AMOUNT);
        victim.approveSpender(address(token), address(staking), AMOUNT);

        vm.expectRevert(bytes("not owner"));
        staking.deligateStake(address(victim), 0, AMOUNT);

        assertEq(token.balanceOf(address(victim)), AMOUNT, "victim kept N");
        assertEq(token.balanceOf(address(staking)), 0, "staking");

        victim.stakeSelf(address(staking), 0, AMOUNT);
        assertEq(token.balanceOf(address(staking)), AMOUNT, "owner stake");
        assertEq(token.balanceOf(address(victim)), 0, "victim after owner stake");
    }
}
