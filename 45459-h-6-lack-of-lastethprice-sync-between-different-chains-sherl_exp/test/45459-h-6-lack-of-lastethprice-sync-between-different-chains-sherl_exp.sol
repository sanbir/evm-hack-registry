// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./45459-h-6-lack-of-lastethprice-sync-between-different-chains-sherl.sol";
contract Finding45459Test is Test {
    function test_exploit_repeated_eth_move_overpays_alice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 6_000_000_000, "6000 USDA");
        assertEq(e.secondLeg(), 200_000_000_000, "repeated leg");
        assertEq(e.usda().balanceOf(address(e.alice())), 6_000_000_000, "alice holds 6000");
    }
    function test_control_synced_price_pays_4000() public {
        Exploit e = new Exploit();
        e.runSynced();
        assertEq(e.usda().balanceOf(address(e.alice())), 4_000_000_000, "synced pays 4000");
    }
}
