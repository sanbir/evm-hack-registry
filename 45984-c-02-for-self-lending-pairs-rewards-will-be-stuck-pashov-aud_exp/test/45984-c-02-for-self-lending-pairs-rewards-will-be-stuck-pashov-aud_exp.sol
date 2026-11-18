// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AutoCompoundingPodLpFixed,
    Dex,
    ERC20,
    Exploit,
    LendingPair
} from "./45984-c-02-for-self-lending-pairs-rewards-will-be-stuck-pashov-aud.sol";

contract Finding45984Test is Test {
    function test_self_lending_reward_underlying_is_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.underlying().balanceOf(address(e.compounder())), 1000 ether, "1000 underlying stuck");
        assertEq(e.fToken().balanceOf(address(e.compounder())), 0, "no fToken");
        assertEq(e.podLp().balanceOf(address(e)), 0, "staker received nothing");
        assertEq(e.compounder().compounded(), 0, "compounded stays 0");
    }

    function test_control_deposit_into_the_pair_compounds() public {
        ERC20 reward = new ERC20("Reward", "RWD");
        ERC20 lpReward = new ERC20("Pod LP Reward", "pLP");
        ERC20 underlying = new ERC20("Borrow Token", "BORROW");
        ERC20 fToken = new ERC20("Lending Share", "fBORROW");
        ERC20 pod = new ERC20("Pod LP", "POD");
        LendingPair pair = new LendingPair(underlying, fToken);
        Dex dex = new Dex();
        AutoCompoundingPodLpFixed fixedCompounder =
            new AutoCompoundingPodLpFixed(reward, lpReward, pair, dex, pod, address(this));
        reward.mint(address(fixedCompounder), 1000 ether);
        fixedCompounder.processRewards(1000 ether);
        assertEq(underlying.balanceOf(address(fixedCompounder)), 0, "underlying was deposited");
        assertEq(pod.balanceOf(address(this)), 1000 ether, "staker received pod LP");
        assertEq(fixedCompounder.compounded(), 1000 ether, "compounded");
    }
}
