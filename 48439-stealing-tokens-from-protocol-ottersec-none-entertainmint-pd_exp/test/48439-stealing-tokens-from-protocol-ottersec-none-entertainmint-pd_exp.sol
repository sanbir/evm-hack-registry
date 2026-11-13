// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Raises} from "./48439-stealing-tokens-from-protocol-ottersec-none-entertainmint-pd.sol";

contract Finding48439Test is Test {
    function test_currency_switch_withdraws_the_other_projects_weth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 10 ether, "stole 10 WETH");
        assertEq(e.fairWeth(), 0, "fix pays no WETH");
        assertEq(e.otherLeft(), 0, "other deposit gone");
        assertFalse(e.fixedApplied(), "fixed updater refused");
        console2.log("taken", e.taken());
        console2.log("other left", e.otherLeft());
    }

    function test_control_fixed_updater_leaves_weth_in_place() public {
        Raises book = new Raises();
        book.fundOther(10 ether);
        book.seedFilledPresale(address(this));

        bool applied = book.updateCurrencyFixed(address(book.weth()));
        assertFalse(applied, "rejected after presale start");
        (, address currency, , , , , , ) = book.attackerRaise();
        assertEq(currency, address(book.dust()), "currency unchanged");
        assertEq(book.weth().balanceOf(address(book)), 10 ether, "WETH stays");
        console2.log("control weth", book.weth().balanceOf(address(book)));
    }
}
