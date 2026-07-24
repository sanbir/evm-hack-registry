// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48950-h-11-rubiconmarket-checks-slippage-incorrectly-code4rena-rub.sol";

contract PoC_48950 is Test {
    function test_slippageCheckedBeforeFee() public {
        Exploit e = new Exploit();
        e.run();
    }
}
