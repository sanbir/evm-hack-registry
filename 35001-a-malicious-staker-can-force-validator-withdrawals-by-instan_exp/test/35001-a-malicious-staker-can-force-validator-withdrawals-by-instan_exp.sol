// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeToken,
    WithdrawalQueue,
    CasimirManager,
    CasimirManagerLocked
} from "./35001-a-malicious-staker-can-force-validator-withdrawals-by-instan.sol";

contract Finding35001Test is Test {
    function test_exploit_instant_unstake_forces_validator_exit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stakeBefore(), 32 ether, "active stake before the unstake");
        assertEq(e.stakeAfter(), 0, "active stake after the forced exit");
        assertEq(e.stakeBefore() - e.stakeAfter(), 32 ether, "validator stake dropped by 32 ETH");
        assertEq(e.queued(), 32 ether, "withdrawal queue gained 32 ETH");
        assertEq(e.token().balanceOf(address(e.queue())), 32 ether, "queue token balance");
        assertEq(e.manager().requestedExits(), 1, "one validator exit");
        assertEq(e.manager().readyValidatorStake(), 32 ether, "ready stake was not the exit target");
        assertEq(e.manager().unstakeQueueAmount(), 1 ether, "only 1 ETH was unstaked");
    }

    function test_control_same_block_unstake_is_rejected() public {
        StakeToken token = new StakeToken();
        WithdrawalQueue queue = new WithdrawalQueue();
        CasimirManagerLocked locked = new CasimirManagerLocked(token, address(queue));
        token.mint(address(this), 64 ether);
        token.approve(address(locked), type(uint256).max);

        locked.seedActiveValidator(32 ether);
        locked.seedUnassigned(31 ether);
        locked.stake(1 ether);

        vm.expectRevert(bytes("unstake locked"));
        locked.requestUnstake(1 ether);

        assertEq(locked.activeValidatorStake(), 32 ether, "control exited the validator");
        assertEq(token.balanceOf(address(queue)), 0, "control queued a withdrawal");
        assertEq(locked.requestedExits(), 0, "control requested an exit");
        assertEq(locked.readyValidatorStake(), 32 ether, "ready stake");
    }
}
