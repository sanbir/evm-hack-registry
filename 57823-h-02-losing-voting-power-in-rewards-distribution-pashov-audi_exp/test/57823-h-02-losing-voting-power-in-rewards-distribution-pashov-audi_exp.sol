// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit, NormalLocker, RewardToken, RewardsDistributorFixed} from "./57823-h-02-losing-voting-power-in-rewards-distribution-pashov-audi.sol";

contract Finding57823Test is Test {
    function test_perpetual_lock_is_paid_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.perpPower(), 0, "perpetual voting power is 0");
        assertEq(e.normalPower(), 1000 ether, "decaying lock keeps its bias");
        assertEq(e.perpPaid(), 0, "perpetual claim is 0");
        assertEq(e.normalPaid(), 1000 ether, "decaying lock takes the full 1000");
        assertEq(e.token().balanceOf(address(e.normal())), 1000 ether, "1000 PEG at the decaying locker");
    }

    function test_control_splits_the_reward() public {
        RewardToken token = new RewardToken();
        RewardsDistributorFixed dist = new RewardsDistributorFixed(token);
        NormalLocker normal = new NormalLocker();
        token.mint(address(dist), 1000 ether);
        dist.createPerpetual(address(this), 1000 ether);
        dist.createNormal(address(normal), 1000 ether);
        uint256 mine = dist.claim(1, 7 days);
        uint256 theirs = dist.claim(2, 7 days);
        assertEq(mine, 500 ether, "perpetual lock receives half");
        assertEq(theirs, 500 ether, "decaying lock receives half");
    }
}
