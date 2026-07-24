// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./54672-owner-can-be-temporarily-changed-within-proxy-calls-allowing.sol";

contract ProxyOwnerSwapTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
