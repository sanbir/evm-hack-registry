// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LP,
    PoolRewardsCapped,
    RewardToken
} from "./61554-poolrewards-arrays-can-grow-without-bounds-resulting-in-dos.sol";

contract Finding61554Test is Test {
    function test_exploit_six_spam_rewards_revert_claim() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.claimReverted(), "claim should revert");
        assertEq(e.entries(), 7, "1 real reward plus 6 spam entries");
        assertEq(e.stuck(), 1000 ether, "1000 RWD stuck");
        assertEq(e.token().balanceOf(LP), 0, "LP received nothing");
    }

    function test_control_cap_lets_claim_pay() public {
        RewardToken token = new RewardToken();
        PoolRewardsCapped pool = new PoolRewardsCapped(token);
        token.mint(address(this), 1000 ether);
        pool.addReward(address(token));
        token.transfer(address(pool), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(PoolRewardsCapped.RewardCap.selector, uint256(1)));
        pool.addReward(address(uint160(1)));
        uint256 paid = pool.claim(LP);
        assertEq(paid, 1000 ether, "capped pool pays 1000 RWD");
        assertEq(token.balanceOf(LP), 1000 ether, "LP received the rewards");
        assertEq(token.balanceOf(address(pool)), 0, "pool emptied");
    }
}
