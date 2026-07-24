// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18200-proposals-could-allow-timelockadmin-takeover-trailofbits-ori.sol";
contract PoC_18200 is Test { function test_exploit() public { new Exploit().run(); } }
