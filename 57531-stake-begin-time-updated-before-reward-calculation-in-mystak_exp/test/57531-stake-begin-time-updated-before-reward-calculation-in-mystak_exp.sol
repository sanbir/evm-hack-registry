// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MyStakingFixed
} from "./57531-stake-begin-time-updated-before-reward-calculation-in-mystak.sol";

contract Finding57531Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant TS = 31_536_001;

    function setUp() public {
        vm.warp(TS);
    }

    function test_exploit_reset_timer_charges_max_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.feeTaken(), 100 ether, "max fee");
        assertEq(e.userNet(), 900 ether, "user net");
        assertEq(e.extraOverFair(), 90 ether, "overcharge");
        assertEq(e.reward().balanceOf(SINK), 100 ether, "fee sink");
        assertEq(e.reward().balanceOf(address(e)), 900 ether, "user");
    }

    function test_control_fee_uses_old_stake_begin() public {
        MiniToken reward = new MiniToken("MY Reward", "MYR");
        MyStakingFixed staking = new MyStakingFixed(reward, SINK);
        reward.mint(address(staking), 1000 ether);
        staking.seed(address(this), 1000 ether);
        staking.stake(0);
        assertEq(staking.lastFee(), 10 ether, "long-stake fee");
        assertEq(staking.lastNet(), 990 ether, "user keeps fee advantage");
        assertEq(reward.balanceOf(SINK), 10 ether, "fair fee");
        assertEq(reward.balanceOf(address(this)), 990 ether, "user");
    }
}
