// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15976-h-03-interest-rates-are-incorrect-on-liquidation-code4rena-p.sol";

contract PoC_15976 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
