// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    GuildFixed
} from "./19347-zero-totallocked-allows-everyone-to-create-proposals-sigmapr.sol";

contract Finding19347Test is Test {
    function test_zero_lock_pays_the_stranger_100e18() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), 100 ether, "stranger received 100e18");
        assertEq(e.guild().locked(address(e)), 0, "caller never locked");
        assertEq(e.asset().balanceOf(address(e.guild())), 0, "guild paid the treasury");
    }

    function test_control_requires_a_lock() public {
        Asset asset = new Asset();
        GuildFixed guild = new GuildFixed(asset);
        asset.mint(address(guild), 100 ether);

        bool paid;
        try guild.createProposal(address(this), 100 ether) {
            paid = true;
        } catch {
            paid = false;
        }
        assertFalse(paid, "stranger with no lock is rejected");
        assertEq(asset.balanceOf(address(guild)), 100 ether, "100e18 stays");
        assertEq(asset.balanceOf(address(this)), 0, "caller received nothing");
    }
}
