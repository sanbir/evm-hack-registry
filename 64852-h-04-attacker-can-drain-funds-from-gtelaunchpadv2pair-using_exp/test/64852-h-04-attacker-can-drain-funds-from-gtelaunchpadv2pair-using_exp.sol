// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64852-h-04-attacker-can-drain-funds-from-gtelaunchpadv2pair-using.sol";

contract SwapFeeDrainTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.drained(), 0, "must drain token0 via phantom amountIn");
    }
}
