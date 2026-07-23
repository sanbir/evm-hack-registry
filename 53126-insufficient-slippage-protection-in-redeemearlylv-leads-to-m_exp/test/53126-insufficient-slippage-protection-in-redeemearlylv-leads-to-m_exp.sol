// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./53126-insufficient-slippage-protection-in-redeemearlylv-leads-to-m.sol";

contract RedeemEarlyMevTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
