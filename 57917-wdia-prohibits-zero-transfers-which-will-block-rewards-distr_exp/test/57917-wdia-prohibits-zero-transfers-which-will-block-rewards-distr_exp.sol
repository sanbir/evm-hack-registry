// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAExternalStakingFixed, Exploit, WDIA} from "./57917-wdia-prohibits-zero-transfers-which-will-block-rewards-distr.sol";

contract Finding57917Test is Test {
    function test_full_principal_share_cannot_unstake() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.beneficiaryCut(), 0, "beneficiary amount is 0");
        assertTrue(e.unstakeReverted(), "zero transfer reverts the unstake");
        assertEq(e.locked(), 1100 ether, "1100 WDIA stays in the pool");
        assertEq(e.token().balanceOf(address(e)), 0, "user received nothing");
    }

    function test_control_skips_the_zero_transfer() public {
        WDIA token = new WDIA();
        DIAExternalStakingFixed staking = new DIAExternalStakingFixed(token);
        token.mint(address(this), 1100 ether);
        token.approve(address(staking), type(uint256).max);
        uint256 index = staking.stake(1000 ether, 10_000);
        staking.addRewardToPool(100 ether);
        staking.requestUnstake(index, 1100 ether);
        staking.unstake(index);
        assertEq(token.balanceOf(address(this)), 1100 ether, "principal and reward returned");
        assertEq(token.balanceOf(address(staking)), 0, "pool empty");
    }
}
