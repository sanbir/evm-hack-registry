// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./31663-h-01-incorrect-quoteweth-implementation-out-of-scope-pashov.sol";

contract Finding31663Test is Test {
    function test_quote_charges_10_and_releases_100() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("quoted", e.helper().quoted());
        console2.log("fair", e.helper().fair());
        console2.log("charged", e.charged());
        console2.log("released", e.released());
        console2.log("kept", e.kept());

        assertEq(e.helper().quoted(), 10 ether, "quote");
        assertEq(e.helper().fair(), 100 ether, "fair");
        assertEq(e.charged(), 10 ether, "charged");
        assertEq(e.released(), 100 ether, "released");
        assertEq(e.kept(), 100 ether, "kept");
        assertGt(e.released(), e.charged(), "underpaid");
    }

    function test_control_quote_is_100() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control charged", e.controlCharged());
        assertEq(e.controlCharged(), 100 ether, "fair");
        assertEq(e.weth().balanceOf(address(e)), 0, "paid in full");
    }
}
