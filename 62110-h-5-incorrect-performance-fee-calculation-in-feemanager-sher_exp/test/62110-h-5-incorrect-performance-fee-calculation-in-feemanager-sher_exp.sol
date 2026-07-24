// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62110-h-5-incorrect-performance-fee-calculation-in-feemanager-sher.sol";
contract PoC_62110 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
