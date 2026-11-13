// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAWhitelistedStakingFixed, Exploit, StakeToken} from "./57913-paidoutreward-subtraction-may-lead-to-unstake-and-unstakepri.sol";

contract Finding57913Test is Test {
    function test_second_unstake_underflows_and_locks_principal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paidOut(), 1000 ether, "paidOutReward stays at 1000");
        assertTrue(e.secondReverted(), "subtraction reverts");
        assertEq(e.locked(), 10_000 ether, "10000 WDIA locked");
        assertEq(e.userGot(), 1000 ether, "only the first reward was paid");
    }

    function test_control_returns_the_principal() public {
        StakeToken token = new StakeToken();
        DIAWhitelistedStakingFixed staking = new DIAWhitelistedStakingFixed(token, 100);
        token.mint(address(this), 11_000 ether);
        token.transfer(address(staking), 11_000 ether);
        uint256 index = staking.openStake(10_000 ether);
        staking.unstake(index);
        staking.requestUnstake(index);
        staking.unstakePrincipal(index);
        assertEq(staking.principalOf(index), 0, "principal cleared");
        assertEq(token.balanceOf(address(staking)), 0, "nothing locked");
        assertEq(token.balanceOf(address(this)), 11_000 ether, "principal and reward returned");
    }
}
