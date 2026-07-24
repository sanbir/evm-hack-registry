// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./43733-h-2-fluidlocker-getunlockingpercentage-uses-540-instead-of-5.sol";
contract PoC_43733 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
