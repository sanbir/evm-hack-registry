// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./57871-h-04-fee-theft-via-arbitrary-contract-impersonation-in-colle.sol";
contract PoC_57871 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
