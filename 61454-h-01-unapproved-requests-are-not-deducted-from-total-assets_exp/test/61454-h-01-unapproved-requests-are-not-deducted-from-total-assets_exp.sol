// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, HyperEvmVault, Honest, MiniToken} from "./61454-h-01-unapproved-requests-are-not-deducted-from-total-assets.sol";

contract UnapprovedRequestsNotDeductedTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_requestRedeem_not_deducted_makes_vault_insolvent() public {
        Exploit e = new Exploit();
        e.run();

        // Outstanding redemption claims exceed the escrow the vault holds:
        // the verbatim requestRedeem never deducted from totalSupply()/tvl().
        assertGt(e.totalClaims(), e.escrowBackingClaims(), "vault should be over-promised");
        assertEq(e.deficit(), 90_000 * 1e6, "insolvency deficit should be 90,000 hUSD");

        // Realized harm: the early requester drains the escrow, the late
        // requester's recorded claim cannot be honored (frozen/lost funds).
        assertEq(e.latePaid(), 0, "late redeemer should be unpaid");
        assertEq(e.shortfall(), e.deficit(), "shortfall equals the insolvency deficit");
        assertEq(e.lateClaim(), 90_000 * 1e6, "late claim priced against stale totals");

        // Harm magnitude recorded at the sink.
        assertEq(e.marker().balanceOf(SINK), e.deficit(), "harm magnitude recorded at sink");
    }
}
