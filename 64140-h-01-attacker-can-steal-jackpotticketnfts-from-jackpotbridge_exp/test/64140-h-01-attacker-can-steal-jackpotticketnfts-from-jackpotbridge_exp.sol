// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64140-h-01-attacker-can-steal-jackpotticketnfts-from-jackpotbridge.sol";

contract MegapotBridgeNftStealTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.nft().ownerOf(e.VICTIM_TICKET()), address(e.thief()), "victim NFT stolen");
        assertEq(e.usdc().balanceOf(address(e.thief())), e.WINNINGS(), "callback USDC");
    }
}
