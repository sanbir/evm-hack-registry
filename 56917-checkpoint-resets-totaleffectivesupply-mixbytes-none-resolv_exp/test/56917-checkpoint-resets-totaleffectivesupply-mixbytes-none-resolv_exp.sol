// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ResolvStaking, FixedStaking, RewardToken} from
    "./56917-checkpoint-resets-totaleffectivesupply-mixbytes-none-resolv.sol";

contract Finding56917Test is Test {
    function test_exploit_supply_zero_rewards_short() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.staking().totalEffectiveSupply(), 0, "supply zeroed");
        assertEq(e.staking().trueEffectiveSum(), 1_000e18, "true supply");
        (, , uint256 claimable) = e.staking().users(e.alice());
        assertEq(claimable, 0, "claimable 0");
        assertEq(e.staking().fairClaim(e.alice()), 1_000e18, "fair 1000");
        assertEq(e.token().balanceOf(address(e.staking())), 1_000e18, "1000 stuck");
    }

    function test_control_keeps_supply_and_pays() public {
        FixedStaking fixedStaking = new FixedStaking();
        fixedStaking.run(1_000e18, 0, 1_000e18);
        assertEq(fixedStaking.totalEffectiveSupply(), 1_000e18, "supply kept");
        assertEq(fixedStaking.claimable(), 1_000e18, "control pays 1000");
    }
}
