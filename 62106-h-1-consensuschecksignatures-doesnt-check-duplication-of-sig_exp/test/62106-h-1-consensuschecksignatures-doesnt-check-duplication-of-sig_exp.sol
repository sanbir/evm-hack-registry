// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62106-h-1-consensuschecksignatures-doesnt-check-duplication-of-sig.sol";
contract PoC_62106 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
