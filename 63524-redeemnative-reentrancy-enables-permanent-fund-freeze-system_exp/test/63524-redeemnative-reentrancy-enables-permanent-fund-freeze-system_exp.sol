// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63524-redeemnative-reentrancy-enables-permanent-fund-freeze-system.sol";

contract NotionalRedeemReentrancyTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
