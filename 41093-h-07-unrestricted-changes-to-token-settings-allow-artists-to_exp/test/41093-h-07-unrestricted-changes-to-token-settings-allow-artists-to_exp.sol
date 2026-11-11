// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Stack} from "./41093-h-07-unrestricted-changes-to-token-settings-allow-artists-to.sol";

contract Finding41093Test is Test {
    function test_exploit_artist_takes_the_whole_sale() public {
        Exploit e = new Exploit();
        e.run();
        Stack s = e.stack();
        (uint32 bps,) = s.nft().royalties();
        assertTrue(s.updated(), "settings changed after mint");
        assertEq(bps, 10_000, "royalty rewritten to 100%");
        assertEq(s.token().balanceOf(address(s)), 1000e18, "artist took 1000e18");
        assertEq(s.token().balanceOf(address(s.seller())), 0, "seller received 0");
        assertEq(s.market().lastCut(), 1000e18, "cut");
    }

    function test_control_frozen_royalty_pays_50e18() public {
        Stack fixedStack = new Stack(true);
        fixedStack.go();
        (uint32 bps,) = fixedStack.nft().royalties();
        assertFalse(fixedStack.updated(), "post-mint edit reverted");
        assertEq(bps, 500, "royalty stayed 500 bps");
        assertEq(fixedStack.token().balanceOf(address(fixedStack)), 50e18, "artist royalty");
        assertEq(fixedStack.token().balanceOf(address(fixedStack.seller())), 950e18, "seller proceeds");
        assertEq(fixedStack.market().lastCut(), 50e18, "cut");
    }
}
