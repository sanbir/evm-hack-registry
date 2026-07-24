// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./33298-tokenbridgebridgetoken-allows-1-way-erc721-bridging-causing.sol";
contract OneWayNftBridgeTest is Test { function test_nftPermanentlyLocks() external { Exploit e = new Exploit(); e.run(); assertEq(e.nft().ownerOf(5), address(e.bridge())); } }
