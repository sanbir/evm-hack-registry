// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MyStakingFixed
} from "./57533-user-funds-lock-in-mystaking-due-to-stakercount-manipulation.sol";

contract Finding57533Test is Test {
    function test_exploit_zero_share_withdraw_locks_staker() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.countAfterAttack(), 0, "count zeroed");
        assertEq(e.victimCouldWithdraw(), false, "withdraw reverted");
        assertEq(e.stuck(), 1000 ether, "1000 locked");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim cannot exit");
    }

    function test_control_zero_share_withdraw_reverts_and_victim_exits() public {
        MiniToken token = new MiniToken();
        MyStakingFixed staking = new MyStakingFixed(token);
        FixedStaker victim = new FixedStaker();
        token.mint(address(victim), 1000 ether);
        victim.stake(token, staking, 1000 ether);
        vm.expectRevert(bytes("not staker"));
        staking.withdraw();
        victim.withdraw(staking);
        assertEq(token.balanceOf(address(staking)), 0, "nothing stuck");
        assertEq(token.balanceOf(address(victim)), 1000 ether, "victim exited");
        assertEq(staking.stakerCount(), 0, "count tracks the real exit");
    }
}

contract FixedStaker {
    function stake(MiniToken token, MyStakingFixed staking, uint256 amount) external {
        token.approve(address(staking), type(uint256).max);
        staking.stake(amount);
    }

    function withdraw(MyStakingFixed staking) external {
        staking.withdraw();
    }
}
