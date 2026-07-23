// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63314-c-01-accepting-duplicate-signatures-from-one-signer-pashov-a.sol";

contract SXTDuplicateSigTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
