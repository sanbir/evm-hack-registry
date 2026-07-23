// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./53108-incorrect-margin-calculation-due-to-inconsistent-realized-an.sol";

contract MarginCalcTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
