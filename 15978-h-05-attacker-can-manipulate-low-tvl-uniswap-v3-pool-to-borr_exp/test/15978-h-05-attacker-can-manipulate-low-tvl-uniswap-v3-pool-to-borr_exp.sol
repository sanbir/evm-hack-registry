// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15978-h-05-attacker-can-manipulate-low-tvl-uniswap-v3-pool-to-borr.sol";

contract PoC_15978 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
