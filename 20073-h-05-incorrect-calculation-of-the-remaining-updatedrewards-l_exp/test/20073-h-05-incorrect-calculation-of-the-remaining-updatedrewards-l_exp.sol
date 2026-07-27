// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";
import "../src/ajna/src/RewardsManager.sol";
import "../src/ajna/src/interfaces/position/IPositionManager.sol";

contract MockAjnaPool {
    function burnInfo(uint256 epoch) external view returns (uint256 burnTime, uint256 totalInterest, uint256 totalBurned) {
        if (epoch == 2) return (block.timestamp, 100 ether, 100 ether);
        return (block.timestamp - 1, 0, 0);
    }
}

contract RewardsHarness is RewardsManager {
    constructor() RewardsManager(address(0xA11CE), IPositionManager(address(1))) {}
    function calculate(address pool, uint256 interest, uint256 nextEpoch, uint256 epoch, uint256 alreadyClaimed)
        external view returns (uint256)
    {
        return _calculateNewRewards(pool, interest, nextEpoch, epoch, alreadyClaimed);
    }
}

contract PoC_20073 is Test {
    RewardsHarness rewards;
    MockAjnaPool pool;

    function setUp() public {
        rewards = new RewardsHarness();
        pool = new MockAjnaPool();
    }

    function test_rewards_cap_underflow_blocks_claim_path() public {
        // The pool's cap is 80% of its own 100 AJNA burn (80 AJNA), while the
        // global epoch tracker already records 81 AJNA claimed by other pools.
        vm.expectRevert();
        rewards.calculate(address(pool), 100 ether, 2, 1, 81 ether);
    }
}
