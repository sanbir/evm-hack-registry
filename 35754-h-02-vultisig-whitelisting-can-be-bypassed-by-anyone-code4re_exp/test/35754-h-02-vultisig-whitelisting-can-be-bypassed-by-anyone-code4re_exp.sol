// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./35754-h-02-vultisig-whitelisting-can-be-bypassed-by-anyone-code4re.sol";
contract Vultisig35754Test is Test { function test_unlistedBuyerBypassesWhitelist() public { Exploit e=new Exploit();e.run();assertEq(e.purchased(),100);assertEq(e.vult().balanceOf(address(e)),100); } }
