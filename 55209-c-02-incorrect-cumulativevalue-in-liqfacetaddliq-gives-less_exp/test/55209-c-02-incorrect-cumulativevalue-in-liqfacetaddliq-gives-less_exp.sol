// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, LiqFacet, MiniToken, MarkerToken} from "./55209-c-02-incorrect-cumulativevalue-in-liqfacetaddliq-gives-less.sol";

// Burve C-02 (finding 55209): LiqFacet::addLiq initializes `cumulativeValue` to
// the post-deposit `tokenBalance` instead of the pre-deposit `preBalance[idx]`,
// inflating the share-formula denominator. The victim adds 10e18, is minted only
// 25e18 shares (should be ~33e18), and recovers just 8e18 on withdrawal — a 2e18
// loss that dilutes into the pre-existing LPs.
contract Finding55209Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_incorrectCumulativeValue_shortsShares() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("deposited", e.depositedByVictim());
        emit log_named_uint("shares minted", e.victimShares());
        emit log_named_uint("withdrawn", e.withdrawnByVictim());
        emit log_named_uint("shortfall", e.shortfall());

        assertEq(e.depositedByVictim(), 10 ether, "victim deposited 10e18");
        assertEq(e.victimShares(), 25 ether, "minted only the buggy 25e18 shares");
        assertEq(e.withdrawnByVictim(), 8 ether, "recovered only 8e18");
        assertLt(e.withdrawnByVictim(), e.depositedByVictim(), "user lost value on deposit");
        assertEq(e.shortfall(), 2 ether, "2e18 silently lost");

        // harm quantified on the SINK marker token
        assertEq(e.marker().balanceOf(SINK), 2 ether, "shortfall recorded to sink");
    }
}
