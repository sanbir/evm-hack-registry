// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, AbstractRewardManager, MockRewardPool, CurveConvex2Token, MiniToken} from "./62486-h-5-migraterewardpool-fails-due-to-incompatible-storage-desi.sol";
contract Finding62486Test is Test {
    function test_migrateRewardPool_ineffective() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.depositedToOldPool(), 100 ether, "deposit went to deprecated old pool");
        assertEq(e.depositedToNewPool(), 0, "migrated pool got nothing");
    }
}
