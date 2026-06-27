// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IWHALE} from "./interfaces/IWHALE.sol";
import {IPancakePair} from "./interfaces/IPancakePair.sol";

/// @dev Minimal callback interface that the WHALE main contract must implement so PolVault can
///      bracket its Pair operations with Method-B LP-tracking reconciliation.
interface IWHALEPolCallback {
    function onPolStart() external;
    function onPolEnd() external;
}

/**
 * @title PolVault
 * @notice Protocol-Owned-Liquidity manager for WHALE v8 — extracted from the main contract.
 *
 * Lifecycle:
 *   1. WHALE routes POL share of each buy/sell tax here via `super._update(this, polVault, share)`.
 *      PolVault is registered as a system-exempt address in WHALE, so these transfers bypass
 *      tax, harvest, and LP-tracking logic.
 *   2. Anyone may call `flushPol()` at any time. `flushPol` swaps half the buffer for USDT
 *      via `pair.swap`, then adds liquidity via `pair.mint`, emitting the resulting LP token
 *      to this vault.
 *
 * v24 §2.10 explicitly forbids calling `removeLiquidity`. POL therefore appreciates passively
 * through PancakeSwap V2's 0.25% swap fee (retained inside reserves).
 *
 * === Design decision: no buffer threshold, no TWAP slippage guard ===
 *
 * `flushPol` is fully permissionless and unconditional. No minimum buffer, no slippage cap.
 * Both safety surfaces are intentionally absent:
 *
 *   - Sandwich attacks need the attacker to pay WHALE's 5-20% sell tax on the front-run plus
 *     the 1% buy tax on the unwind. The buffer-half quoted into the pair gets routed via
 *     this vault (a system address in WHALE, not subject to tax) so the swap-side leg pays
 *     only Pancake's 0.25% fee — but the attacker's bracketing trades pay WHALE's full tax.
 *     Net of taxes the round-trip is structurally unprofitable for the attacker regardless
 *     of buffer size. Removing the threshold allows continuous, smaller flushes which keep
 *     the per-flush price impact small and the gross sandwich opportunity proportionally
 *     small too.
 *
 *   - A TWAP-bounded slippage guard would introduce a DoS surface. Natural price moves
 *     (new listings, news volatility, sparse-block windows) could leave `flushPol`
 *     reverting; an attacker could maintain a persistent spot deviation via routine trades,
 *     letting the buffer grow into a larger target when the guard eventually lifts. Pinning
 *     the tolerance to a value loose enough for BSC volatility but tight enough to bound
 *     attacker profit is not data-supportable pre-launch.
 *
 * Caller reward — paid ONLY on the WHALE-mediated path:
 * `flushPolForUser(recipient)` (controller-only) is reachable EXCLUSIVELY when a
 * user transfers `POL_TRIGGER_AMOUNT` WHALE to `fomoVault` and WHALE's Layer 15
 * forwards here with the original sender as `recipient`. That call pays the
 * recipient `min(buffer × 0.5%, 10 WHALE)` up-front. Layer 15 also gates on
 * `from == msg.sender && tx.origin == msg.sender` so contract callers /
 * `transferFrom`-relayed calls cannot harvest the reward without the FOMO
 * donation requirement. (v9 dropped the redundant `msg.sender.code.length
 * == 0` check so EIP-7702 delegated EOAs aren't false-rejected; `tx.origin
 * == msg.sender` already blocks every non-EOA + constructor-bypass case.)
 *
 * `flushPol()` is the public-good entry — anyone may call it any time to advance
 * POL bookkeeping (`_swapWHALEToUsdt` + `_addLiquidity`), but pays NO caller reward
 * (`_doFlushPol(address(0))` skips the reward block). This prevents attackers
 * from collecting the 0.5% reward without paying the FOMO donation. MEV bots
 * lose the direct-flush incentive, but the WHALE-mediated path remains attractive
 * to whoever is willing to donate `POL_TRIGGER_AMOUNT` to FOMO.
 *
 * @dev No shadow counters. Balances are authoritative:
 *        - WHALE buffer = `token.rawBalanceOf(this)`
 *        - USDT buffer = `usdt.balanceOf(this)`
 *        - LP balance = `pair.balanceOf(this)`
 */
contract PolVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ============================================================
    // Errors
    // ============================================================

    error ZeroAddress();
    error SwapSlippage();
    error TransferFailed();
    error OnlyController();
    error InvalidRecipient();

    // ============================================================
    // Events
    // ============================================================

    /// @dev Detailed accounting of one POL flush:
    ///   `bufferProcessed`  — total WHALE input drawn from the vault buffer (= half + remainder)
    ///   `whaleSwapped`       — half of buffer actually swapped for USDT (0 if reserves degenerate)
    ///   `usdtReceived`     — USDT obtained from the swap leg
    ///   `whaleAddedToLp`     — WHALE put into addLiquidity (= bufferProcessed - whaleSwapped)
    ///   `usdtAddedToLp`    — USDT put into addLiquidity (≤ usdtReceived; remainder stays as
    ///                        residue if AMM ratio capped one side)
    ///   `liquidityAdded`   — LP shares minted to this vault
    event PolFlushed(
        address indexed caller,
        uint256 bufferProcessed,
        uint256 whaleSwapped,
        uint256 usdtReceived,
        uint256 whaleAddedToLp,
        uint256 usdtAddedToLp,
        uint256 liquidityAdded
    );

    // ============================================================
    // Constants
    // ============================================================

    /// @dev Caller reward as a fraction of the buffer at flush time. 0.5% = 50 bps.
    uint256 public constant FLUSH_REWARD_BPS = 50;
    /// @dev Per-call hard cap on the caller reward (in WHALE wei). Bounds dust-flush
    ///      griefing economics: even an attacker spamming flushes against a giant
    ///      buffer extracts at most this much per call.
    uint256 public constant FLUSH_REWARD_MAX = 10 * 1e18;

    // ============================================================
    // Immutables
    // ============================================================

    IWHALE public immutable token;
    IERC20 public immutable usdt;
    IPancakePair public immutable pair;
    IWHALEPolCallback public immutable controller;

    // ============================================================
    // Constructor (v6.8.4: full immutable, no init pattern)
    // ============================================================

    /// @notice Set all wired state as immutable. The cycle (vault needs WHALE_addr +
    ///         pair_addr, WHALE creates pair inside its own constructor) is broken
    ///         off-chain via deterministic CREATE2 prediction:
    ///           - WHALE_addr predicted from CREATE2(arachnid, salt_WHALE, init_code(registry))
    ///           - pair_addr predicted from PancakeFactory CREATE2(USDT, WHALE_addr)
    ///           - Both fed to PolVault constructor at vault deploy time.
    ///         See `src/HashrateRegistry.sol` for the full cycle-resolution flow.
    /// @param _controller WHALE main contract (= token).
    /// @param _usdt       Quote token.
    /// @param _pair       PancakePair address (predicted from factory + USDT + WHALE).
    constructor(address _controller, IERC20 _usdt, IPancakePair _pair) {
        if (_controller == address(0)) revert ZeroAddress();
        if (address(_usdt) == address(0)) revert ZeroAddress();
        if (address(_pair) == address(0)) revert ZeroAddress();

        token = IWHALE(_controller);
        usdt = _usdt;
        pair = _pair;
        controller = IWHALEPolCallback(_controller);
    }

    // ============================================================
    // External — flushPol (permissionless)
    // ============================================================

    /**
     * @notice Swap half of the accumulated WHALE buffer for USDT, then add liquidity.
     * @dev Permissionless public-good flush: anyone may call it to advance POL
     *      bookkeeping, but **NO caller reward is paid here**. The 0.5% reward
     *      is exclusively gated on the WHALE-mediated path (`flushPolForUser`,
     *      reachable only by transferring `POL_TRIGGER_AMOUNT` WHALE to
     *      `fomoVault`). Otherwise a contract could call this directly and
     *      harvest the reward without contributing anything to the FOMO pool —
     *      defeating the incentive design.
     *
     *      Bracketed by `onPolStart`/`onPolEnd` callbacks so the controller can
     *      reconcile any pending user-LP attribution before/after Pair state
     *      changes.
     * @return liquidityAdded LP tokens minted to this vault.
     */
    function flushPol() external nonReentrant returns (uint256 liquidityAdded) {
        return _doFlushPol(address(0));
    }

    /// @notice Variant for the WHALE-mediated UX path: user transfers
    ///         `POL_TRIGGER_AMOUNT` WHALE to `fomoVault`, WHALE detects the magic value
    ///         and forwards here with the original sender as `recipient`. Caller
    ///         reward (0.5% of buffer, capped at FLUSH_REWARD_MAX) is paid to
    ///         `recipient` instead of `msg.sender` (which is the WHALE contract).
    /// @dev Restricted to `controller` so the magic-value entry point cannot be
    ///      spoofed; the rewarded path is reachable EXCLUSIVELY via this entry.
    function flushPolForUser(address recipient) external nonReentrant returns (uint256 liquidityAdded) {
        if (msg.sender != address(controller)) revert OnlyController();
        if (recipient == address(0)) revert InvalidRecipient();
        return _doFlushPol(recipient);
    }

    /// @dev Pass `rewardRecipient = address(0)` for the no-reward (public-good)
    ///      path; pass a non-zero recipient for the WHALE-mediated reward path.
    function _doFlushPol(address rewardRecipient) internal returns (uint256 liquidityAdded) {
        uint256 buffer = token.rawBalanceOf(address(this));

        // Caller reward: 0.5% of buffer up-front, capped at FLUSH_REWARD_MAX (10 WHALE).
        // Cap bounds spam economics; ratio incentivizes MEV-driven frequent flushes
        // proportional to buffer size, keeping per-flush sandwich impact small.
        // Only paid on the WHALE-mediated path — `rewardRecipient == 0` skips it.
        if (rewardRecipient != address(0)) {
            uint256 reward = buffer * FLUSH_REWARD_BPS / 10_000;
            if (reward > FLUSH_REWARD_MAX) reward = FLUSH_REWARD_MAX;
            if (reward > 0) {
                if (!token.transfer(rewardRecipient, reward)) revert TransferFailed();
                unchecked { buffer -= reward; }
            }
        }

        controller.onPolStart();

        // Buffer == 0 path is a no-op: `_swapWHALEToUsdt(0)` and `_addLiquidity(0, _)`
        // both early-return zeros without touching the pair. No revert, just an empty
        // PolFlushed event.
        uint256 half = buffer / 2;
        uint256 usdtReceived = _swapWHALEToUsdt(half);
        uint256 whaleRemaining = buffer - half;
        (uint256 whaleAddedToLp, uint256 usdtAddedToLp, uint256 liq) =
            _addLiquidity(whaleRemaining, usdt.balanceOf(address(this)));
        liquidityAdded = liq;

        controller.onPolEnd();

        emit PolFlushed(
            rewardRecipient,
            buffer,
            half,
            usdtReceived,
            whaleAddedToLp,
            usdtAddedToLp,
            liquidityAdded
        );
    }

    // ============================================================
    // Views
    // ============================================================

    function whaleBuffer() external view returns (uint256) {
        return token.rawBalanceOf(address(this));
    }

    function usdtBuffer() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    function lpBalance() external view returns (uint256) {
        return pair.balanceOf(address(this));
    }

    // ============================================================
    // Internal — Pair interaction
    // ============================================================

    function _swapWHALEToUsdt(uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return 0;

        uint256 amountInWithFee = amountIn * 9_975;
        uint256 numerator = amountInWithFee * uint256(r0);
        uint256 denominator = uint256(r1) * 10_000 + amountInWithFee;
        amountOut = numerator / denominator;
        if (amountOut == 0) return 0;

        // `token.transfer(pair, ...)` triggers WHALE._update(polVault, pair, amount). PolVault is a
        // system-exempt address in WHALE — Layer 2 early-returns without applying tax or LP tracking.
        if (!token.transfer(address(pair), amountIn)) revert TransferFailed();

        uint256 usdtBefore = usdt.balanceOf(address(this));
        pair.swap(amountOut, 0, address(this), "");
        uint256 usdtReceived = usdt.balanceOf(address(this)) - usdtBefore;
        if (usdtReceived < amountOut) revert SwapSlippage();
        return usdtReceived;
    }

    function _addLiquidity(uint256 whaleAmount, uint256 usdtAmount)
        internal
        returns (uint256 useWHALE, uint256 useUsdt, uint256 liquidity)
    {
        if (whaleAmount == 0 || usdtAmount == 0) return (0, 0, 0);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == 0 || r1 == 0) return (0, 0, 0);

        uint256 optimalUsdt = whaleAmount * uint256(r0) / uint256(r1);
        if (optimalUsdt <= usdtAmount) {
            useWHALE = whaleAmount;
            useUsdt = optimalUsdt;
        } else {
            useUsdt = usdtAmount;
            useWHALE = usdtAmount * uint256(r1) / uint256(r0);
        }
        if (useWHALE == 0 || useUsdt == 0) return (0, 0, 0);

        if (!token.transfer(address(pair), useWHALE)) revert TransferFailed();
        usdt.safeTransfer(address(pair), useUsdt);
        liquidity = pair.mint(address(this));
    }
}
