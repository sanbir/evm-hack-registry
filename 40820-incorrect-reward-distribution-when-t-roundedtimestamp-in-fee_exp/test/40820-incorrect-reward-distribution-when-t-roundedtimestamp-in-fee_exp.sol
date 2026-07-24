// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./40820-incorrect-reward-distribution-when-t-roundedtimestamp-in-fee.sol";

contract FeeDistEpochTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
