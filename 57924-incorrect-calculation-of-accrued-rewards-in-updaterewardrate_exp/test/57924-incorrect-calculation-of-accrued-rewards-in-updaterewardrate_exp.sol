// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {DIARewardsDistributionFixed, Exploit, StakeToken} from "./57924-incorrect-calculation-of-accrued-rewards-in-updaterewardrate.sol";

contract Finding57924Test is Test {
    function setUp() public {
        vm.warp(8_640_001);
    }

    function test_rate_update_accrues_20_instead_of_100000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.accrued(), 20, "accumulator gained 20");
        assertEq(e.received(), 20 ether, "user is paid 20");
        assertEq(e.kept(), 99_980 ether, "99980 stays undistributed");
    }

    function test_control_uses_the_old_rate_without_the_extra_division() public {
        StakeToken token = new StakeToken();
        DIARewardsDistributionFixed dist = new DIARewardsDistributionFixed(token, 1000);
        token.mint(address(dist), 100_000 ether);
        dist.updateRewardRatePerDay(2000);
        uint256 paid = dist.claim();
        assertEq(paid, 100_000 ether, "old rate over 100 days pays 100000");
        assertEq(token.balanceOf(address(dist)), 0, "the fair amount was paid");
    }
}
