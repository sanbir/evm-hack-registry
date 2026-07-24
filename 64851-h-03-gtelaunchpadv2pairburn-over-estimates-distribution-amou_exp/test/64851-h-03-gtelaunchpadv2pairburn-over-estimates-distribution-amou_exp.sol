// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64851-h-03-gtelaunchpadv2pairburn-over-estimates-distribution-amou.sol";

contract BurnFeeOverclaimTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.stolenFeeShare(), 0, "must steal positive fee share via over-claim burn");
        assertGt(e.profit0(), 0, "token0 profit");
    }
}
