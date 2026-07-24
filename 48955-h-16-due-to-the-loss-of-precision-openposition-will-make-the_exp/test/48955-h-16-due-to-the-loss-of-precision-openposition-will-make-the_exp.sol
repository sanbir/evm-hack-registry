// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48955-h-16-due-to-the-loss-of-precision-openposition-will-make-the.sol";

contract PoC_48955 is Test {
    function test_precisionLossLeverage() public {
        Exploit e = new Exploit();
        e.run();
    }
}
