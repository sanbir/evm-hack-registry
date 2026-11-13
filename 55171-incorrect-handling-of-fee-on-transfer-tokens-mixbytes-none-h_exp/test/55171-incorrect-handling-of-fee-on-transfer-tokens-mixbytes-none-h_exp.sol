// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./55171-incorrect-handling-of-fee-on-transfer-tokens-mixbytes-none-h.sol";

contract Finding55171Test is Test {
    function test_nominal_credit_takes_100_from_the_honest_balance() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("profit", e.profit());
        console2.log("honest short", e.honestShort());
        assertEq(e.profit(), 100 ether, "profit");
        assertEq(e.honestShort(), 100 ether, "short");
        assertEq(e.token().balanceOf(address(e.lob())), 900 ether, "left");
    }

    function test_control_credits_900_and_the_attacker_is_flat() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control profit", e.controlProfit());
        assertEq(e.controlProfit(), 0, "flat");
        assertEq(e.token().balanceOf(address(e.fixedLob())), 1_000 ether, "backed");
    }
}
