// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IncentiveLogicFixed,
    IncentivizedERC20,
    LpHolder,
    PoolManager,
    RecycledToken,
    RewardToken
} from "./61562-rewards-can-be-stolen-when-incentivizederc20-tokens-are-recu.sol";

contract Finding61562Test is Test {
    function test_exploit_claims_reward_token() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.reward().balanceOf(address(e)), 100 ether, "attacker took N");
        assertEq(e.reward().balanceOf(address(e.holder())), 0, "lp holder paid 0");
        assertEq(e.logic().poolUserLiquidity(e.POOL_ID(), address(e.manager())), 100 ether, "manager holds liq");
        emit log_named_uint("stolen reward", e.reward().balanceOf(address(e)));
    }

    function test_control_rejects_recycled_token() public {
        RewardToken reward = new RewardToken();
        IncentiveLogicFixed logic = new IncentiveLogicFixed();
        PoolManager manager = new PoolManager();
        IncentivizedERC20 lp = new IncentivizedERC20(address(logic), bytes32(uint256(1)));
        LpHolder holder = new LpHolder();
        logic.setRecycled(address(lp));

        reward.mint(address(this), 100 ether);
        reward.approve(address(logic), 100 ether);
        logic.depositRewards(address(reward), 100 ether);
        lp.mint(address(holder), 100 ether);
        logic.credit(bytes32(uint256(1)), address(holder), 100 ether);
        holder.approveToken(address(lp), address(manager), 100 ether);

        vm.expectRevert(RecycledToken.selector);
        manager.recycle(address(lp), address(holder), 100 ether);

        assertEq(logic.poolUserLiquidity(bytes32(uint256(1)), address(holder)), 100 ether, "liq stays");
        logic.claim(bytes32(uint256(1)), address(reward), address(holder), address(holder));
        assertEq(reward.balanceOf(address(holder)), 100 ether, "holder paid N");
        assertEq(reward.balanceOf(address(manager)), 0, "manager paid 0");
    }
}
