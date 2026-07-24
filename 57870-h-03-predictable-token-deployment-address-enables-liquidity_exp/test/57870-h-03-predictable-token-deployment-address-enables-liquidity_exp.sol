// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./57870-h-03-predictable-token-deployment-address-enables-liquidity.sol";
contract PoC_57870 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
