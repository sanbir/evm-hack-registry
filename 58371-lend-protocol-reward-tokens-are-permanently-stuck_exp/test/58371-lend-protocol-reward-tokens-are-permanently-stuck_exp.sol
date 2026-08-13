// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, Collateral} from "./58371-lend-protocol-reward-tokens-are-permanently-stuck.sol";

// Lend H-2 (finding 58371): liquidateSeizeUpdate accrues 2.8% of seized collateral
// into lendStorage.protocolReward, which is only ever incremented and has no
// withdrawal path. Seize 1000e18 -> 28e18 stuck in the router forever.
contract Finding58371Test is Test {
    function test_protocolReward_permanentlyStuck() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("seizeTokens", e.seizeTokens());
        emit log_named_uint("stuck reward (2.8%)", e.stuckReward());
        emit log_named_uint("liquidator redeemed (97.2%)", e.liquidatorRedeemed());

        assertEq(e.seizeTokens(), 1000e18, "seized full collateral");
        assertEq(e.stuckReward(), 28e18, "2.8% stranded in protocolReward");
        assertEq(e.liquidatorRedeemed(), 972e18, "liquidator got 97.2%");
        assertGt(e.stuckReward(), 0, "collateral permanently stuck");

        // Sink marker: the permanently-stuck 2.8% is a concrete measurable balance.
        Collateral col = e.collateral();
        assertEq(col.balanceOf(0x000000000000000000000000000000000000D00d), 28e18, "sink holds stuck magnitude");
    }
}
