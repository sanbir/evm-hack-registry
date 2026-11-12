// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, AdlUtils} from "./18631-h-5-adl-operations-do-not-have-any-slippage-protection-sherl.sol";

contract Finding18631Test is Test {
    function test_adl_close_pays_below_stated_minimum() public {
        Exploit e = new Exploit();
        e.run();

        AdlUtils market = e.market();
        console2.log("stated minimum", e.statedMinimum());
        console2.log("user received", e.traderReceived());
        console2.log("pool retained", e.poolRetained());
        console2.log("acceptable price", e.acceptablePrice());
        console2.log("min output", e.minOutputAmount());
        console2.log("price impact diff", market.priceImpactDiff());

        assertEq(e.statedMinimum(), 10_000 ether, "minimum");
        assertEq(e.traderReceived(), 4_000 ether, "received");
        assertLt(e.traderReceived(), e.statedMinimum(), "worse");
        assertEq(e.poolRetained(), 6_000 ether, "retained");
        assertEq(e.poolRetained(), e.statedMinimum() - e.traderReceived(), "gap");
        assertEq(e.acceptablePrice(), 0, "acceptablePrice");
        assertEq(e.minOutputAmount(), 0, "minOutputAmount");
        assertEq(e.token().balanceOf(e.TRADER()), 4_000 ether, "trader balance");
        assertEq(e.token().balanceOf(address(market)), 6_000 ether, "pool balance");
        assertEq(market.paidToUser(), 4_000 ether, "paid");
        assertEq(market.cappedPrice(), 1_800 ether, "capped price");
        assertEq(market.pnlAtCap(), 8_000 ether, "pnl at cap");
        assertEq(market.priceImpactDiff(), 6_000 ether, "diff");
        assertTrue(market.priceAccepted(), "price accepted");
        assertTrue(market.poolPnlFactorFell(), "global check");
        assertFalse(market.controlBlocked(), "vulnerable path paid");
    }

    function test_control_enforces_the_minimum() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control blocked", e.controlBlocked());
        console2.log("control paid", e.controlPaid());

        assertTrue(e.controlBlocked(), "4000 fill refused");
        assertEq(e.controlPaid(), 10_000 ether, "cap pays the minimum");
        assertEq(e.token().balanceOf(e.TRADER()), 10_000 ether, "trader received the minimum");
        assertEq(e.token().balanceOf(address(e.market())), 0, "pool did not keep the diff");
        assertGe(e.controlPaid(), 10_000 ether, "not below the minimum");
    }
}
