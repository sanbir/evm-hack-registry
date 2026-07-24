// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./53453-h-01-excess-payment-when-plugin-owner-reduces-price-shieldif.sol";
contract PoC_53453 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
