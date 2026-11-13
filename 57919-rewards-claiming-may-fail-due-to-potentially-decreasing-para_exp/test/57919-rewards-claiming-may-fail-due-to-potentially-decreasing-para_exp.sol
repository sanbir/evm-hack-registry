// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    DIAWhitelistedStakingFixed,
    Exploit,
    StakeToken
} from "./57919-rewards-claiming-may-fail-due-to-potentially-decreasing-para.sol";

contract Finding57919Test is Test {
    function test_second_unstake_reverts_and_locks_half() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.leftPrincipal(), 5_000 ether, "5000 principal remains");
        assertEq(e.storedReward(), 1_000 ether, "stored reward stays at the pre-decrease value");
        assertTrue(e.secondReverted(), "updateReward assert reverts");
        assertEq(e.token().balanceOf(address(e.staking())), 5_000 ether, "5000 WDIA locked");
        assertEq(e.userGot(), 6_000 ether, "first half plus 1000 reward was paid");
    }

    function test_control_second_unstake_pays_the_rest() public {
        StakeToken token = new StakeToken();
        DIAWhitelistedStakingFixed staking = new DIAWhitelistedStakingFixed(token, 100);
        token.mint(address(this), 11_000 ether);
        token.transfer(address(staking), 11_000 ether);
        uint256 index = staking.stake(10_000 ether);
        staking.unstakePrincipal(index, 5_000 ether);
        staking.unstakePrincipal(index, 5_000 ether);
        assertEq(staking.principalOf(index), 0, "principal fully returned");
        assertEq(token.balanceOf(address(staking)), 0, "nothing locked");
        assertEq(token.balanceOf(address(this)), 11_000 ether, "user received principal and the 1000 reward");
    }
}
