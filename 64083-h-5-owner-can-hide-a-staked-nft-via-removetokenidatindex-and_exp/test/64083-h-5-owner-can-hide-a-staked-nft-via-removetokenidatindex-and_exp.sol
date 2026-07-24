// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64083-h-5-owner-can-hide-a-staked-nft-via-removetokenidatindex-and.sol";
contract PoC_64083 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
