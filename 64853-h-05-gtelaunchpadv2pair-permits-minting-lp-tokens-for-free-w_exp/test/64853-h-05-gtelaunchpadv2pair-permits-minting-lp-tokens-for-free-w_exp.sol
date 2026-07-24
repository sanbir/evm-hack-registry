// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64853-h-05-gtelaunchpadv2pair-permits-minting-lp-tokens-for-free-w.sol";

contract FreeMintTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.freeLP(), 0, "free LP minted");
        assertGt(e.stolen0(), 0, "token0 stolen");
        assertGt(e.stolen1(), 0, "token1 stolen");
    }
}
