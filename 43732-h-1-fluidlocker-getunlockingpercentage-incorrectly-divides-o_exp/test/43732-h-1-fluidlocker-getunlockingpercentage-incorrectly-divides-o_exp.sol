// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./43732-h-1-fluidlocker-getunlockingpercentage-incorrectly-divides-o.sol";
contract PoC_43732 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
