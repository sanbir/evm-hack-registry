// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIAWhitelistedStakingFixed, Exploit, StakeToken} from "./57918-rewards-are-lost-if-user-requests-unstake-in-less-than-one-d.sol";

contract Finding57918Test is Test {
    function test_twelve_hours_pays_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quoted(), 0, "passedDays is 0");
        assertEq(e.paid(), 0, "claim pays 0");
        assertEq(e.kept(), 50 ether, "50 WDIA stays in the contract");
    }

    function test_control_pays_the_half_day() public {
        StakeToken token = new StakeToken();
        DIAWhitelistedStakingFixed staking = new DIAWhitelistedStakingFixed(token, 100);
        token.mint(address(this), 50 ether);
        token.transfer(address(staking), 50 ether);
        uint256 index = staking.openStake(10_000 ether);
        uint256 paid = staking.unstake(index);
        assertEq(paid, 50 ether, "12 hours pays 50");
        assertEq(token.balanceOf(address(staking)), 0, "reward was paid");
    }
}
