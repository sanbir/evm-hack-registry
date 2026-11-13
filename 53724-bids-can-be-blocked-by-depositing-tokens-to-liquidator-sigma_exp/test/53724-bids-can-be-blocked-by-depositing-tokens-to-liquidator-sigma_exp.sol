// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53724-bids-can-be-blocked-by-depositing-tokens-to-liquidator-sigma.sol";

contract Finding53724Test is Test {
    function test_wrapped_deposit_blocks_the_bid_and_books_5000() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("uncovered", e.uncovered());
        assertTrue(e.bidBlocked(), "blocked");
        assertEq(e.uncovered(), 5_000 ether, "short");
        assertEq(e.cash().balanceOf(address(e.liq())), 5_000 ether, "booked");
    }

    function test_control_approval_lets_the_bid_collect_5000() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control collected", e.controlCollected());
        assertEq(e.controlCollected(), 5_000 ether, "collected");
        assertEq(e.fixedLiq().uncovered(), 0, "covered");
    }
}
