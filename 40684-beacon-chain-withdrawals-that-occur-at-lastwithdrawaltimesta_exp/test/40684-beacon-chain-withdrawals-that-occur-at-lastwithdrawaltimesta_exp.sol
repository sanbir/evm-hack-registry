// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./40684-beacon-chain-withdrawals-that-occur-at-lastwithdrawaltimesta.sol";

contract EigenPodTsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
