// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./34767-h-5-updatepositionfrombalancemargin-function-returns-0-if-am.sol";

contract Finding34767Test is Test {
    function test_weth_margin_is_0_instead_of_30_and_30_is_borrowed() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("last change", e.book().lastChange());
        console2.log("weth left", e.left());
        console2.log("borrowed", e.took());

        assertEq(e.book().lastChange(), 0, "change");
        assertEq(e.left(), 0, "weth");
        assertEq(e.took(), 30 ether, "borrow");
        assertEq(e.token().balanceOf(address(e)), 30 ether, "received");
    }

    function test_control_leaves_weth_margin_at_30() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("fair weth left", e.fairLeft());
        assertEq(e.fairLeft(), 30 ether, "kept");
    }
}
