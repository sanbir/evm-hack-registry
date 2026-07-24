// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./54691-requirevalidadjustmentincurrentmode-bypass-when-not-in-mintl.sol";

contract MintListBypassTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
