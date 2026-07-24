// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48952-h-13-when-opening-a-position-the-collateral-of-the-previous.sol";

contract PoC_48952 is Test {
    function test_priorCollateralReused() public {
        Exploit e = new Exploit();
        e.run();
    }
}
