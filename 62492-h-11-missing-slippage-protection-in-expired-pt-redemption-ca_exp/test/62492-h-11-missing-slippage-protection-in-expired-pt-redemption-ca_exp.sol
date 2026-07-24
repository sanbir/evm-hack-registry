// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62492-h-11-missing-slippage-protection-in-expired-pt-redemption-ca.sol";
contract PoC_62492 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
