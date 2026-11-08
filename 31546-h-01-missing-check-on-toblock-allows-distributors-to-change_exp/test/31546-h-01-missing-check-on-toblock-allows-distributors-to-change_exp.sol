// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    SQD,
    DistributedRewardsDistribution
} from "./31546-h-01-missing-check-on-toblock-allows-distributors-to-change.sol";

contract DistributedRewardsFixed is DistributedRewardsDistribution {
    constructor(address _token, address _distributor) DistributedRewardsDistribution(_token, _distributor) {}

    function commit(
        uint256 fromBlock,
        uint256 toBlock,
        uint256[] calldata recipients,
        uint256[] calldata workerRewards,
        uint256[] calldata stakerRewards
    ) public override {
        require(toBlock > fromBlock, "Invalid block span");
        super.commit(fromBlock, toBlock, recipients, workerRewards, stakerRewards);
    }
}

contract Finding31546Test is Test {
    function test_exploit_toBlock_zero_pays_the_same_epoch_twice() public {
        vm.roll(10);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.firstCredit(), 100e18, "first commit credited one epoch");
        assertEq(e.secondCredit(), 200e18, "second commit credited the epoch again");
        assertEq(e.token().balanceOf(address(e)), 200e18, "worker received both payments");
        assertEq(e.token().balanceOf(address(e.rewards())), 0, "treasury was emptied");
        assertEq(e.rewards().lastBlockRewarded(), 0, "cursor is still open");
    }

    function test_control_invalid_span_cannot_reset_the_cursor() public {
        vm.roll(10);
        SQD token = new SQD();
        DistributedRewardsFixed rewards = new DistributedRewardsFixed(address(token), address(this));
        token.mint(address(rewards), 200e18);

        uint256[] memory recipients = new uint256[](1);
        uint256[] memory workerRewards = new uint256[](1);
        uint256[] memory stakerRewards = new uint256[](1);
        recipients[0] = 1;
        workerRewards[0] = 100e18;

        vm.expectRevert(bytes("Invalid block span"));
        rewards.commit(1, 0, recipients, workerRewards, stakerRewards);

        rewards.commit(1, 5, recipients, workerRewards, stakerRewards);
        assertEq(rewards.claimableOf(1), 100e18, "one epoch credited");
        assertEq(rewards.lastBlockRewarded(), 5, "cursor advanced");

        vm.expectRevert(bytes("Not all blocks covered"));
        rewards.commit(1, 9, recipients, workerRewards, stakerRewards);

        uint256 paid = rewards.claim(1);
        assertEq(paid, 100e18, "worker received one epoch");
        assertEq(token.balanceOf(address(this)), 100e18, "no second payment");
        assertEq(token.balanceOf(address(rewards)), 100e18, "the other epoch stayed in the treasury");
    }
}
