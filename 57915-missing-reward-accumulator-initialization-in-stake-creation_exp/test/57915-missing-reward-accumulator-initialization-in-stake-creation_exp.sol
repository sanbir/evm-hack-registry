// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAWhitelistedStakingFixed, Exploit, StakeToken} from "./57915-missing-reward-accumulator-initialization-in-stake-creation.sol";

contract Finding57915Test is Test {
    function test_new_stake_claims_the_historical_index() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimed(), 1000 ether, "claimed 1000 of historical rewards");
        assertEq(e.profit(), 1000 ether, "net theft is 1000");
        assertEq(e.token().balanceOf(address(e.staking())), 0, "reward pool emptied");
    }

    function test_control_initializes_the_user_index() public {
        StakeToken token = new StakeToken();
        DIAWhitelistedStakingFixed staking = new DIAWhitelistedStakingFixed(token, 1000);
        token.mint(address(this), 10_000 ether);
        token.mint(address(staking), 1000 ether);
        token.approve(address(staking), 10_000 ether);
        uint256 index = staking.stake(10_000 ether);
        uint256 claimed = staking.claim(index);
        staking.unstakePrincipal(index);
        assertEq(claimed, 0, "a new stake earns nothing historical");
        assertEq(token.balanceOf(address(staking)), 1000 ether, "historical rewards stay");
        assertEq(token.balanceOf(address(this)), 10_000 ether, "principal returned");
    }
}
