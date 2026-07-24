// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./55229-h-2-malicious-validators-will-bypass-consensus-threshold-req.sol";
contract PoC_55229 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
