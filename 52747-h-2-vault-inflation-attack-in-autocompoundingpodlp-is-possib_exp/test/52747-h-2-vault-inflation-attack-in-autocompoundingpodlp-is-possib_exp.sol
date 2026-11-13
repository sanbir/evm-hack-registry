// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./52747-h-2-vault-inflation-attack-in-autocompoundingpodlp-is-possib.sol";

contract Finding52747Test is Test {
    function test_exploit_inflation_steals_from_the_next_depositor() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerProfit(), 3921167270471535599, "profit");
        assertEq(e.victimLoss(), 3921167270471535599, "loss");
        assertEq(e.asset().balanceOf(address(e)), 20 ether + 3921167270471535599, "balance");
    }

    function test_control_dead_shares_cannot_be_withdrawn() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.vault().balanceOf(address(0xdead)), 1000, "dead");
        assertEq(e.vault().totalAssets(), 1000, "stuck");
        assertEq(e.asset().balanceOf(address(e)), 20 ether - 1000, "kept");
    }
}
