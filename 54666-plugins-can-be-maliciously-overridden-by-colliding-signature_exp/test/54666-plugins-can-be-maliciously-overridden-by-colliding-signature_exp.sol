// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./54666-plugins-can-be-maliciously-overridden-by-colliding-signature.sol";

contract PluginOverrideTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
