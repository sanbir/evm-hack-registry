// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61525-incorrect-oracle-staleness-period-price-feed-dos.sol";

contract PoC_61525 is Test {
    function test_global_staleness_rejects_valid_slow_feed() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.staleFeedDos());
        assertTrue(exploit.heartbeatWouldAccept());
    }
}
