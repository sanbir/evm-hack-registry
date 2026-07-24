// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32312-h-01-magnetarmintxchainmodulesolmintbblendxchainsgl-can-be-u.sol";

contract MintXChainUserMismatchTest is Test {
    function test_compose_user_mismatch_drains_victim() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.token().balanceOf(exp.VICTIM()), 0, "victim drained");
        assertEq(exp.magnetar().lentOf(exp.VICTIM()), exp.AMOUNT(), "forced position");
    }
}
