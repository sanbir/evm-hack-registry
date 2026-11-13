// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    GuildFixed
} from "./19345-low-totallocked-may-result-in-guild-takeover-sigmaprime-none.sol";

contract Finding19345Test is Test {
    function test_one_wei_lock_moves_100e18() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), 100 ether, "attacker received 100e18");
        assertEq(e.guild().totalLocked(), 1, "majority was 1 wei");
        assertEq(e.asset().balanceOf(address(e)), 100 ether, "exploit holds the treasury");
    }

    function test_control_requires_1000e18_locked() public {
        Asset asset = new Asset();
        GuildFixed guild = new GuildFixed(asset);
        asset.mint(address(guild), 100 ether);
        guild.lock(1);

        bool moved;
        try guild.execute(address(this), 100 ether) {
            moved = true;
        } catch {
            moved = false;
        }
        assertFalse(moved, "dust lock cannot execute");
        assertEq(asset.balanceOf(address(guild)), 100 ether, "treasury stays");
        assertEq(asset.balanceOf(address(this)), 0, "caller received nothing");
    }
}
