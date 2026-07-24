// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44371-h-1-unsafe-type-casting-in-token-amount-handling-sherlock-ok.sol";
contract PoC_44371 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
