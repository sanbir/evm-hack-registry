// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61396-h-01-session-key-can-be-consumed-by-unauthorized-scw-shieldi.sol";
contract PoC_61396 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
