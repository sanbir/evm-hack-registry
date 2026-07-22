// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26976-h-08-if-governance-removes-a-gauge-users-voting-power-for-th.sol";

/*//////////////////////////////////////////////////////////////
    Canto (veRWA) — GaugeController.remove_gauge() strands voting power
    (H-08, #26976)

    remove_gauge() zeroes a gauge's weight but never touches the individual
    vote_user_slopes/vote_user_power entries of anyone who voted for it. Because
    vote_for_gauge_weights() requires isValidGauge[_gauge_addr] even to submit a
    ZERO vote, a voter who committed 100% of their power to a gauge that is later
    removed can never redirect OR reclaim that power again.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the stranded-power harm from the driver's perspective.
    - test_removedGaugeStrandsVotingPower: standalone rebuild mirroring the
      finding's own PoC almost line-for-line (gov votes all-in on gauge1,
      gauge1 is removed, gauge2 vote reverts, zeroing gauge1 reverts).
    - test_removingAnUnusedGauge_isHarmless: control — removing a gauge nobody
      voted on is completely safe, isolating "had an outstanding vote" as the
      precondition for the harm.
//////////////////////////////////////////////////////////////*/
contract GaugeRemovalStrandsPowerTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        GaugeController gc = e.gc();
        assertEq(gc.vote_user_power(address(e)), 10_000, "exploit's power is permanently stuck");
        assertFalse(gc.isValidGauge(e.GAUGE1()), "gauge1 stays removed");
    }

    /// @notice Standalone rebuild mirroring the finding's PoC (`testPOC`) as
    ///         closely as the reduced contracts allow.
    function test_removedGaugeStrandsVotingPower() public {
        MockVotingEscrow ve = new MockVotingEscrow();
        GaugeController gc = new GaugeController(address(ve), address(this));

        address gauge1 = address(0xBEEF1);
        address gauge2 = address(0xBEEF2);

        ve.setUser(address(this), 1e15, block.timestamp + 1825 days);

        gc.add_gauge(gauge1);
        gc.change_gauge_weight(gauge1, 100);
        gc.add_gauge(gauge2);
        gc.change_gauge_weight(gauge2, 100);

        // All-in on gauge1.
        gc.vote_for_gauge_weights(gauge1, 10_000);

        // Governance removes gauge1.
        gc.remove_gauge(gauge1);

        // Cannot vote for gauge2 — power is still "used" by the removed gauge1.
        vm.expectRevert(bytes("Used too much power"));
        gc.vote_for_gauge_weights(gauge2, 10_000);

        // Cannot remove the vote for gauge1 either.
        vm.expectRevert(bytes("Invalid gauge address"));
        gc.vote_for_gauge_weights(gauge1, 0);

        // Demonstrate again that voting power is not (and cannot be) freed.
        vm.expectRevert(bytes("Used too much power"));
        gc.vote_for_gauge_weights(gauge2, 10_000);

        assertEq(gc.vote_user_power(address(this)), 10_000, "power forever stuck on the removed gauge");
    }

    /// @notice Control: removing a gauge that nobody voted for is harmless —
    ///         isolates "had an outstanding vote on the removed gauge" as the
    ///         actual precondition for the harm above.
    function test_removingAnUnusedGauge_isHarmless() public {
        MockVotingEscrow ve = new MockVotingEscrow();
        GaugeController gc = new GaugeController(address(ve), address(this));

        address gaugeUnused = address(0xBEEF3);
        address gauge2 = address(0xBEEF2);

        ve.setUser(address(this), 1e15, block.timestamp + 1825 days);

        gc.add_gauge(gaugeUnused);
        gc.add_gauge(gauge2);

        // Nobody ever voted for gaugeUnused.
        gc.remove_gauge(gaugeUnused);

        // Voting power is untouched (0 used so far) — a fresh vote on gauge2
        // works fine, because there was never any stranded power to begin with.
        gc.vote_for_gauge_weights(gauge2, 10_000);
        assertEq(gc.vote_user_power(address(this)), 10_000, "fresh vote succeeds when nothing was stranded");
    }
}
