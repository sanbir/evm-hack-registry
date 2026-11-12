// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58121-h-01-inconsistent-spread-and-price-impact-charges-pashov-aud.sol";

contract Finding58121Test is Test {
    function test_exploit_trader_pays_half_then_nothing_on_close() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paidWrong(), 250e18, "trader paid 250 DAI");
        assertEq(e.closeFee(), 0, "pre-v9.2 close charged nothing");
        assertEq(e.paidFair(), 500e18, "control charged 500 DAI");
        assertEq(e.book().feesCollected(), 250e18, "protocol received the half charge");
        assertEq(e.fairBook().feesCollected(), 500e18, "control received spread plus impact");
    }
}
