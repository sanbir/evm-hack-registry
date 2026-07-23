// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LicredityPool
} from "./62349-self-triggered-licredity-afterswap-back-run-enables-lp-fee-f.sol";

contract AfterSwapFeeFarmingTest is Test {
    function test_abuse_backswap_fees() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.notionalAfter(), e.notionalBefore(), "notional rose");
        assertGt(e.profit(), 0, "profit > 0");
        assertGe(e.pool().price(), e.pool().ONE(), "price restored");
    }
}
