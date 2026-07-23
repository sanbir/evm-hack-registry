// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63173-h-7-makercollectfees-re-targets-liquidity-to-original-amount.sol";

contract AmmplifyCollectFeesRetargetTest is Test {
    function test_exploit_collectFeesRestoresOriginalLiq() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.liqAfterAdjust(), 100e18);
        assertEq(e.liqAfterCollect(), 300e18);
    }
}
