// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPancakePair} from "./interfaces/IPancakePair.sol";
import {PowMath} from "./libs/PowMath.sol";
import {HashrateRegistry} from "./HashrateRegistry.sol";
/// @notice Minimal WHALE interface used by WHALEHashrate. Defined inline to avoid importing
///         the full WHALE contract (which would re-introduce the WHALE↔Hashrate compile cycle).
interface IWHALE {
    function awardMiningEmission(address to, uint256 amount) external;
    /// @dev Used by `_previewAccumulators` to detect a pending pre-open bootstrap
    ///      stage (the deployer's atomic addLp before `openTrading()`). Set by
    ///      WHALE's Layer 3 short-circuit / Layer 8c `_stagePending`, cleared by
    ///      Layer 7a settle.
    function lastTransfer() external view returns (address);
    // totalEmitted() removed: Critical 3 fix moved cap-clamp from realized-mint
    // (`whale.totalEmitted`) to debt-counter (`accountedEmission` in this contract).
    // queueReferralReward removed: `notifyCredit` returns reward-trigger info
    // synchronously so WHALE fires `refVault.triggerReward` directly.
}

/// @title WHALEHashrate (hWHALE)
/// @notice Externalized hashrate as a transferable ERC20 token. Mirrors v7.x WHALE's mining
///         + referral + node logic but lives in its own contract. Holds the authoritative
///         LP commitment ledger (`registeredLp`) which is atomic with the hashrate balance
///         on every mint / burn / transfer — preventing phantom-mining via the v8
///         transferHashrate semantics.
///
///         Cross-contract entry points (star topology — only WHALE↔Hashrate, no vault calls):
///           - WHALE → notifyCredit / notifyDebit / notifyHarvest (onlyWHALE)
///           - WHALE → notifyMagicBind / bindReceiver (onlyWHALE)
///           - WHALEHashrate → whale.awardMiningEmission (only hashrate→WHALE cross-call; in
///             `_harvest`, `_distributeDynamic`, `_updateNodeStatus`)
///         One-shot referral reward: `notifyCredit` RETURNS the trigger info
///         (refToReward, hashrateUsed); WHALE fires `refVault.triggerReward` directly.
///         Only the LP-backed addLp path (`notifyCredit`) can return a non-zero ref;
///         transferHashrate (`_propagateUp`) and bind back-credit (`_executeBind`)
///         do not — Sybil one-shot drain blocked by construction.
///
///         Storage / logic copied & adapted from v7.x WHALE. Delta:
///           - `userHashrate` mapping → `balanceOf` (ERC20)
///           - `totalHashrate` → `totalSupply()` (ERC20)
///           - NEW `registeredLp[u]` mapping (atomic with balance, replaces whale.userLp)
///           - `_propagateUp / _propagateDown` separated for clarity (was inline in v7.x's
///             `_propagateCreditToReferrer` + `_debitLpUsdt`)
contract WHALEHashrate is ERC20, ReentrancyGuardTransient {
    // ============================================================
    // Constants
    // ============================================================

    /// @dev USDT-equivalent thresholds (18 decimals). Compared against `balanceOf(u)` and
    ///      `sharedHashrate[u]` — same semantics as v7.x's userHashrate / sharedHashrate.
    /// @dev TWO distinct reward thresholds with different semantics:
    ///      - `REF_REWARD_USDT` (~20): per-event LP-backed gate for the ONE-SHOT
    ///        direct referral reward in `notifyCredit`. Low threshold to keep
    ///        the reward accessible to small participants. Sybil-proof by
    ///        construction (the triggering hashrate must come from a real LP
    ///        commitment).
    ///      - `VALID_INVITE_USDT` (~200): "valid downline" qualification. Drives
    ///        `validDownlines` counter (used as multi-gen distribution gate)
    ///        AND the floor rule in `_update` — a sender holding ≥ threshold
    ///        cannot transfer below it, blocking Sybil-via-transfer of
    ///        validDownlines (attacker can't recycle the same stake across
    ///        alts). Bounded Sybil at floor(H / threshold) per stake remains,
    ///        but each "slot" requires real LP commitment and locked principal.
    ///
    ///      All thresholds carry a 0.5% buffer below the documented round-number
    ///      target (e.g. 200 → 199) to absorb typical AMM slippage / timing drift
    ///      between user-intended USDT amount and actual settle value (a 200
    ///      USDT addLp can land at 199.99 due to inter-block price moves).
    ///      Whitepaper / front-end may continue to advertise the round numbers.
    uint256 private constant REF_REWARD_USDT = 4975 * 1e16;      // 49.75 (round target 50)
    uint256 private constant VALID_INVITE_USDT = 199 * 1e18;     // (round target 200)
    uint256 private constant NODE_LP_USDT = 995 * 1e18;          // (round target 1000)
    uint256 private constant NODE_PERF_USDT = 2_985 * 1e18;      // (round target 3000)

    /// @dev Magic-value transfer that consumes balance to register a referrer
    ///      binding. 0.001 WHALE. Same numeric value as `WHALE.MAGIC_TRANSFER_AMOUNT`
    ///      / `WHALE.POL_TRIGGER_AMOUNT`; disambiguated by recipient.
    uint256 public constant REFCODE_AMOUNT = 1 * 10 ** 15;

    /// @dev 80% of static reward goes to the 15-generation dynamic distribution.
    uint256 private constant DYNAMIC_POOL_BPS = 8_000;

    /// @dev 15-generation dynamic distribution ratios (bps), packed 12 bits per entry.
    ///      Identical to v7.x WHALE's RATIOS_PACKED.
    uint256 private constant RATIOS_PACKED = (uint256(2_500) << 0) | (uint256(625) << 12)
        | (uint256(625) << 24) | (uint256(625) << 36) | (uint256(625) << 48) | (uint256(625) << 60)
        | (uint256(625) << 72) | (uint256(625) << 84) | (uint256(625) << 96) | (uint256(625) << 108)
        | (uint256(375) << 120) | (uint256(375) << 132) | (uint256(375) << 144) | (uint256(375) << 156)
        | (uint256(375) << 168);

    /// @dev Per-generation valid-downlines threshold, packed 4 bits per entry.
    ///      [1,1,2,2,3,3,4,4,5,5,6,6,7,7,7] for gens 1..15. Identical to v7.x.
    uint256 private constant THRESHOLDS_PACKED = (uint256(1) << 0) | (uint256(1) << 4)
        | (uint256(2) << 8) | (uint256(2) << 12) | (uint256(3) << 16) | (uint256(3) << 20)
        | (uint256(4) << 24) | (uint256(4) << 28) | (uint256(5) << 32) | (uint256(5) << 36)
        | (uint256(6) << 40) | (uint256(6) << 44) | (uint256(7) << 48) | (uint256(7) << 52)
        | (uint256(7) << 56);

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ============================================================
    // Emission constants
    // ============================================================

    /// @dev Emission seed (A-curve anchor). Identical to WHALE's `D0`.
    ///      `aCum_max = D0 * 500 = MINING_MAX` exactly (protocol design),
    ///      so `_calculateEmission` is implicitly cap-bounded without a
    ///      cross-call to `whale.totalEmitted()`. `whale.awardMiningEmission` saturates
    ///      at MINING_MAX independently as a defense-in-depth check.
    uint256 private constant D0 = 41_958 * 1e18;
    uint256 private constant EMIT_STATIC_PCT = 50;
    uint256 private constant EMIT_NODE_PCT = 10;

    // ============================================================
    // Immutable wiring
    // ============================================================

    /// @notice WHALE main contract. Sole authority for `notifyCredit` / `notifyDebit` /
    ///         `notifyHarvest` / `notifyMagicBind` callbacks. Recipient of
    ///         `awardMiningEmission` cross-calls (cap enforcement lives there).
    IWHALE public immutable whale;
    /// @notice PancakeSwap pair (WHALE/USDT). WHALE is token1 by deploy invariant
    ///         (`address(WHALE) > address(USDT)`), so reserve1 = `circ` for emission.
    IPancakePair public immutable pair;
    /// @notice RefVault funding sink for unqualified-hierarchy share. When a 15-gen
    ///         distribution skips a generation (validDownlines below threshold),
    ///         the would-be share is batched and minted here instead of being
    ///         no-mint-burned. Speeds up the one-shot direct-referral reward queue
    ///         in early-stage / sparse-tree conditions.
    address public immutable refVault;

    // ============================================================
    // Storage
    // ============================================================

    /// @notice LP commitment ledger. Authoritative source for "how much pair LP backs each
    ///         user's hashrate". Atomic with `balanceOf(user)` via `_update` override.
    mapping(address => uint256) public registeredLp;

    // Slot-packed: openTime (8B) + lastEmissionUpdate (8B) + lastTickRWHALE (14B) = 30B (2B free).
    /// @notice Anchor for the closed-form emission integrator. Set at constructor
    ///         block.timestamp (trading is live from deploy — no openTrading step).
    uint64 public openTime;
    /// @dev Anchor for closed-form emission integration. Advances on every `_tickEmission`.
    uint64 internal lastEmissionUpdate;
    /// @dev rWHALE at the time of the last successful tick. The NEXT tick uses THIS
    ///      value (not the current pair reserve) for emission integration over the
    ///      `[lastEmissionUpdate, now]` window. Closes the High-5 flash-manipulation
    ///      vector: an attacker who pumps `pair.balanceOf(WHALE)` right before calling
    ///      `tickEmission()` cannot retroactively inflate the elapsed window's
    ///      emission, because the tick uses the rWHALE recorded at the START of the
    ///      window, not the END. Combined with "every pair WHALE transfer triggers
    ///      tick" (Layer 8 `notifyHarvest`), manipulation only affects future
    ///      windows whose duration ≈ 0 in flash-loan scenarios (pump and reverse
    ///      both fire ticks in same block → elapsed=0 → emission=0).
    /// @dev Starts at 0 (pair has no reserves at constructor); the first
    ///      `_tickEmission` that runs with `ts > 0` will be the bootstrap addLp
    ///      settle, which then advances this anchor. The empty-tree path
    ///      (`ts == 0 && nodeCt == 0`) short-circuits to no-emission so the
    ///      zero start value is safe.
    uint112 internal lastTickRWHALE;

    /// @notice Per-unit-hashrate accumulator for static mining rewards (50% of emission).
    uint256 public staticAccPerShare;
    /// @notice Per-node accumulator for node mining rewards (10% of emission).
    uint256 public nodeAccPerShare;

    /// @dev Snapshot of `staticAccPerShare` when `user` last harvested.
    mapping(address => uint256) internal userIndex;
    /// @dev Snapshot of `nodeAccPerShare` when `user` last harvested as node.
    mapping(address => uint256) internal userNodeIndex;

    mapping(address => bool) public isNode;
    uint256 public totalNodeCount;

    /// @notice Referral tree: `user → upline`.
    mapping(address => address) public referrer;
    /// @notice Sum of direct downlines' hashrate balance. Maintained by `_propagateUp/Down`.
    mapping(address => uint256) public sharedHashrate;
    /// @notice Live count of direct downlines whose `balanceOf` ≥ VALID_INVITE_USDT.
    ///         Used as the dynamic-distribution threshold gate.
    mapping(address => uint256) public validDownlines;
    /// @dev v9: `rewardTriggered` mapping removed. v8 used it as a one-shot
    ///      latch (referrer earned only on the downline's FIRST qualifying
    ///      addLp). v9 fires reward on EVERY qualifying addLp ≥ REF_REWARD_USDT.

    /// @notice Cumulative emission written into accumulators (debt; may exceed
    ///         `whale.totalEmitted()` until users harvest). Used as the cap-headroom
    ///         signal in `_calculateEmission` — `aRemaining = aCum - accountedEmission`.
    ///         Critical 3 fix: prior cap used `whale.totalEmitted()` which counts ONLY
    ///         realized mints, letting accumulator-write/harvest race issue O(N²)
    ///         excess emission across days under B-curve dominance.
    /// @dev Invariant: `accountedEmission >= whale.totalEmitted()` always (debt ≥ paid).
    ///      Bounded by `aCum_max == MINING_MAX` so cannot exceed the protocol cap.
    uint256 public accountedEmission;

    // ============================================================
    // Errors
    // ============================================================

    error ZeroAddress();
    error OnlyWHALE();
    error InvalidBind();
    error SharedHashrateUnderflow();
    /// @dev Thrown by `notifyDebit` when WHALE attempts to debit more LP than the user has
    ///      registered. Catches the v8 phantom-mining attack: attacker transferred hashrate
    ///      (and registeredLp) away, then tried to redeem LP via Method-B without the
    ///      matching ledger. Reverting here unwinds the entire user tx.
    error InsufficientRegisteredLp();
    /// @dev Sybil floor rule: a sender holding ≥ VALID_INVITE_USDT cannot transfer
    ///      down to below the threshold. Prevents recycling the same 200-hashrate
    ///      "slot" across multiple alts to inflate `validDownlines`. Once below the
    ///      threshold, transfers are unrestricted (the slot is already "spent").
    error TransferBelowValidFloor();

    // ============================================================
    // Events
    // ============================================================

    event HashrateCredited(address indexed user, uint256 lpDelta, uint256 hashrate);
    event HashrateDebited(address indexed user, uint256 lpRemoved, uint256 hashrate);
    event StaticReward(address indexed user, uint256 amount);
    event NodeReward(address indexed user, uint256 amount);
    event DynamicReward(
        address indexed recipient, address indexed origin, uint8 generation, uint256 amount
    );
    event HierarchyBurn(address indexed recipient, uint256 amount);
    event NodeAdded(address indexed user);
    event NodeRemoved(address indexed user);
    /// @dev Emitted on every bind (4 user-facing paths + receiver self-loop init).
    ///      Replaces v7.x's `RefVault.ReferrerBound` — indexers should listen here.
    event ReferrerBound(address indexed downline, address indexed referrer);
    /// @dev Emitted when WHALE's constructor calls `bindReceiver` to install the
    ///      `_receiver` self-loop in the referral tree.
    event ReceiverInitialized(address indexed receiver);

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyWHALE() {
        if (msg.sender != address(whale)) revert OnlyWHALE();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    /// @param registry      HashrateRegistry with predicted WHALE / pair / refVault addresses.
    /// @param receiver      Referral tree root. Installed as `referrer[receiver] = receiver`
    ///                       (self-loop) so the root has a sentinel non-zero referrer.
    constructor(
        HashrateRegistry registry,
        address receiver
    ) ERC20("WHALE Hashrate", "hWHALE") {
        address _whale = registry.whale();
        address _pair = registry.pair();
        address _refVault = registry.refVault();
        if (_whale == address(0) || _pair == address(0) || _refVault == address(0)) {
            revert ZeroAddress();
        }
        if (receiver == address(0) || receiver == DEAD) revert ZeroAddress();
        whale = IWHALE(_whale);
        pair = IPancakePair(_pair);
        refVault = _refVault;

        // Install referral tree root self-loop. Atomically anchored at
        // WHALEHashrate construction time so it can't be missed by a
        // malformed deploy.
        referrer[receiver] = receiver;
        emit ReceiverInitialized(receiver);
        emit ReferrerBound(receiver, receiver);

        // Emission curve anchors: trading is live from deploy — there is no
        // separate openTrading() step. Both `openTime` and `lastEmissionUpdate`
        // start at this contract's construction block.timestamp. WHALE deploys a
        // few seconds later and re-anchors its own clock; the tiny delta is
        // irrelevant because the empty-tree path (ts == 0) emits 0 anyway.
        uint64 nowU64 = uint64(block.timestamp);
        openTime = nowU64;
        lastEmissionUpdate = nowU64;
        // lastTickRWHALE starts at 0 — first real tick (post-initial-LP) reads
        // pair reserves directly via `_calculateEmission`.
    }

    // ============================================================
    // External — WHALE-only notify endpoints
    // ============================================================

    /// @notice Called by WHALE after Layer 7a settles a confirmed addLp. Increments
    ///         `registeredLp[user]`, mints proportional hashrate, and RETURNS the
    ///         one-shot referral-reward trigger info to WHALE for direct queueing.
    ///
    ///         Architectural note: returning the trigger info (rather than
    ///         calling back into WHALE via `queueReferralReward`) collapses the
    ///         hashrate→WHALE cross-call edge for one-shot rewards. WHALE becomes the
    ///         single point that knows when to fire `refVault.triggerReward`.
    ///
    /// @param user             LP attribution target (Method-B `lastTransfer`).
    /// @param lpDelta          Pair LP minted to user (post-mint-fee).
    /// @param currentRUsdt   Post-mint USDT reserve (`pair.getReserves().reserve0`).
    ///                       Read at settle time, not stage time — Router atomicity
    ///                       guarantees no third party mutates pair state between
    ///                       Layer 8c stage and Layer 7a settle within one addLp tx.
    /// @param currentTotalLp Post-mint `pair.totalSupply()`. Used as the denominator
    ///                       in `hashAmount = 2 × lpDelta × currentRUsdt / currentTotalLp`,
    ///                       which equals the user's LP-share of the post-mint pool.
    /// @return refToReward     Non-zero ⟺ WHALE should queue a one-shot referral reward
    ///                         to this address. Zero address means no fire (either no
    ///                         cross-up, no upline, already-latched, or systemic skip).
    /// @return hashrateUsed    The user's post-credit hashrate (only meaningful when
    ///                         `refToReward != 0`); used by WHALE to compute reward
    ///                         amount via spot/TWAP price.
    function notifyCredit(
        address user,
        uint256 lpDelta,
        uint256 currentRUsdt,
        uint256 currentTotalLp
    ) external onlyWHALE nonReentrant returns (address refToReward, uint256 hashrateUsed) {
        if (user == address(0) || lpDelta == 0 || user == DEAD) return (address(0), 0);
        if (currentTotalLp == 0) return (address(0), 0);

        // Hashrate identity (mirrors v7.x `_inferPendingHashrate`):
        //   hashrate = WHALE × TWAP + USDT, but LP-share derivation gives
        //   USDT-equivalent = lpDelta × rUSDT / TS, and WHALE-side equals it
        //   at stage TWAP, so total = 2 × USDT-side.
        uint256 hashAmount = 2 * lpDelta * currentRUsdt / currentTotalLp;

        // ALWAYS credit registeredLp (even when hashAmount == 0 due to dust/rounding).
        // This keeps user's removeLp path open; the alternative (early-return drops their
        // LP into a locked state). On the rare dust-addLp case, invariant A relaxes —
        // registeredLp > 0 with balance == 0 — but the user can still recover their LP
        // via Router.removeLiquidity (gate 1 will pass because ledger > 0).
        unchecked {
            registeredLp[user] += lpDelta;
        }

        if (hashAmount == 0) {
            // Dust addLp: no hashrate to mint, no propagation needed. Skip _mint to avoid
            // emitting a zero-value Transfer (gas saver) and exit early.
            emit HashrateCredited(user, lpDelta, 0);
            return (address(0), 0);
        }

        // Atomic with `registeredLp` increment above. super._update will trigger our
        // `_update` override which auto-harvests `to` BEFORE the balance change — same
        // ordering invariant as v7.x's "harvest before changing hashrate".
        // _propagateUp inside Step 4 of _update will increment validDownlines on cross-up
        // (live counter), but will NOT fire the one-shot referral reward — that fires
        // ONLY via the return value below.
        _mint(user, hashAmount);

        emit HashrateCredited(user, lpDelta, hashAmount);

        // ONE-SHOT REFERRAL REWARD (PER-EVENT THIS-ADDLP-ONLY) — return to WHALE.
        //
        // v8 semantic: the reward fires only when a SINGLE addLp commits hashrate
        // (= USDT-equivalent of LP backing) ≥ REF_REWARD_USDT (20 USDT-eq).
        // Cumulative balance is NOT considered — neither prior addLps nor pre-loaded
        // transfer hashrate can bridge the threshold.
        //
        // Sybil-proof by construction: an attacker cannot pre-load an alt with
        // hashrate via transfer (free) and cross the threshold via dust addLp.
        // The dust addLp's `hashAmount` is well below 20 USDT-eq → gate doesn't
        // pass → no reward fires.
        //
        // Threshold split (v9):
        //   - REF_REWARD_USDT  = 50  → per-event reward gate (this check; no latch).
        //   - VALID_INVITE_USDT = 200 → validDownlines gate (live counter +
        //     floor rule). Reward fires regardless of validDownlines status;
        //     the latter only affects multi-gen dynamic distribution eligibility.
        if (hashAmount >= REF_REWARD_USDT) {
            address ref = referrer[user];
            if (ref != address(0) && ref != DEAD) {
                return (ref, hashAmount);
            }
        }
        // NOTE: FomoVault.notifyLpAdd is fired by WHALE._settlePendingLpAdd AFTER this
        // call returns — keeps vault controller surface = WHALE only (no dual-controller
        // needed). WHALE also fires `refVault.triggerReward` post-notifyCredit when this
        // function returns a non-zero ref.
        return (address(0), 0);
    }

    /// @notice Called by WHALE after Layer 7b reconciles a burn. AUTHORITATIVE LP-ledger
    ///         check happens here — reverts the entire user tx if `registeredLp[user]`
    ///         cannot cover `lpRemoved` (i.e., the user transferred hashrate away then
    ///         tried to remove LP without the matching ledger).
    /// @param user      Burn attribution target (`pair.burn(to)` recipient).
    /// @param lpRemoved Pair LP burned in this op.
    function notifyDebit(address user, uint256 lpRemoved) external onlyWHALE nonReentrant {
        if (user == address(0) || lpRemoved == 0) return;

        uint256 registered = registeredLp[user];
        if (registered < lpRemoved) revert InsufficientRegisteredLp();

        // Full-clear shortcut: avoids `bal × lpRemoved` overflow risk at extreme values
        // and exact-zeroes dust on full removal (preserves the
        // `balanceOf(u) > 0 ⟺ registeredLp(u) > 0` invariant after exit).
        uint256 bal = balanceOf(user);
        uint256 hashAmount = (lpRemoved == registered) ? bal : (bal * lpRemoved) / registered;

        unchecked {
            registeredLp[user] = registered - lpRemoved;
        }
        // `_burn` triggers `_update(user, 0, hashAmount)` which:
        //   - harvests user's pending rewards (pre-burn balance)
        //   - debits sharedHashrate via _propagateDown (may revert SharedHashrateUnderflow
        //     if invariant broken; in practice impossible because credit/debit pairing
        //     is exact under v8 atomic semantics).
        if (hashAmount > 0) _burn(user, hashAmount);

        emit HashrateDebited(user, lpRemoved, hashAmount);
    }

    /// @notice Called by WHALE at every Layer 7a/8 to materialize a user's pending rewards.
    ///         `_harvest` self-ticks emission internally — the up-to-date accumulator
    ///         is read inside the harvest body.
    function notifyHarvest(address user) external onlyWHALE nonReentrant {
        _harvest(user);
    }

    /// @notice Magic-value bind triggered by WHALE._update Layer 4 (`whale.transfer(upline, X)`
    ///         where X ∈ {0, REFCODE_AMOUNT}). Same gates as the hWHALE-side path.
    /// @return bound True if `from` was successfully bound to `to`. Caller (WHALE) consumes
    ///               the magic transfer (super._update + return) iff true.
    function notifyMagicBind(address from, address to) external onlyWHALE nonReentrant returns (bool) {
        return _tryBindReferral(from, to);
    }

    // ============================================================
    // External — User-facing
    // ============================================================

    /// @notice Materialize the caller's pending mining rewards into WHALE. Useful for
    ///         hodlers who never move their hashrate.
    function claim() external nonReentrant {
        _harvest(msg.sender);
    }

    /// @notice Permissionless ping for the emission curve. Anyone can advance the
    ///         accumulator; useful for keepers between user activity. No reward
    ///         materializes — that requires a per-user `claim()` afterwards.
    function tickEmission() external nonReentrant {
        _tickEmission();
    }

    /// @notice View-only daily emission projection for the current day-index.
    function dailyEmission() external view returns (uint256) {
        return _dailyEmission((block.timestamp - openTime) / 1 days);
    }

    /// @notice Live pending WHALE rewards user would receive on `claim()` right now.
    ///         Sums (a) static reward = `balance * (liveStaticAcc - userIndex) / 1e18`
    ///         and (b) node reward = `(liveNodeAcc - userNodeIndex) / 1e18` (if node).
    ///         Excludes downstream dynamic distribution from downlines (those mint
    ///         when downlines themselves harvest, not on this user's claim).
    ///
    ///         Used by `WHALE.balanceOf` to surface the virtual-credit balance to
    ///         wallets / DEX UIs (`raw + pending = perceived balance`).
    function pendingRewards(address user) external view returns (uint256 total) {
        if (user == DEAD || user == address(0)) return 0;

        // Fast-path: zero-hashrate non-node has no pending. Skip the expensive
        // `_previewAccumulators` cross-call (pair.getReserves + pow998).
        // Hot path because `WHALE.balanceOf` calls this on every external read,
        // and most wallets/buyers have no hashrate (haven't done addLp yet).
        uint256 hash = balanceOf(user);
        bool node = isNode[user];
        if (hash == 0 && !node) return 0;

        (uint256 liveStatic, uint256 liveNode,, ) = _previewAccumulators();

        if (hash > 0) {
            uint256 idx = userIndex[user];
            if (liveStatic > idx) {
                total = (hash * (liveStatic - idx)) / 1e18;
            }
        }

        if (node) {
            uint256 nIdx = userNodeIndex[user];
            if (liveNode > nIdx) {
                total += (liveNode - nIdx) / 1e18;
            }
        }
    }

    /// @notice Bind `msg.sender` to `upline` directly (no magic-value transfer required).
    ///         Same gates as the REFCODE_AMOUNT path; useful for first-time onboarding
    ///         when caller has zero hWHALE balance.
    /// @dev Self-ticks emission at top so the downstream `_executeBind →
    ///      _updateNodeStatus(upline)` reads a CURRENT `nodeAccPerShare` when
    ///      the bind crosses the upline through `NODE_PERF_USDT`. Other callers
    ///      of `_updateNodeStatus` either rely on Step 2 `_harvest` having
    ///      ticked upstream (transfer/burn paths) or on the iron-rule pre-tick
    ///      semantics (notifyCredit mint path — Trap 17). This direct entry
    ///      has neither, so it must tick itself.
    function bindReferral(address upline) external nonReentrant {
        _tickEmission();
        // `_tryBindReferral` reverts on invalid upline (self / system / orphan) and
        // returns false when caller is already bound. For the explicit direct-bind
        // entry point we treat already-bound as an error too (caller's intent is to
        // bind — not a pass-through transfer).
        if (!_tryBindReferral(msg.sender, upline)) revert InvalidBind();
    }

    // ============================================================
    // ERC20 transfer with harvest hook + atomic registeredLp move
    // ============================================================

    /// @dev Override of OZ ERC20's `_update`. Adds:
    ///        1. Magic-value REFCODE_AMOUNT detection → bindReferral
    ///        2. Auto-harvest BOTH sides BEFORE balance change (uses pre-update balance
    ///           to avoid accumulator-arbitrage)
    ///        3. ATOMIC registeredLp proportional move (fully local — no cross-call):
    ///             lpProp = registeredLp[from] × value / balanceOf(from)
    ///        4. Referral-tree propagation + node-status update on both sides AFTER super
    ///
    ///      Mint path (from = 0):  step 2 (to-only), step 3 skipped, step 4 (to-only) — by
    ///      `from != 0` guard. Burn path (to = 0): symmetric. System addresses skip steps
    ///      2 / 3 / 4 to avoid polluting referral state (vault transfers, address(this)
    ///      transfers).
    function _update(address from, address to, uint256 value) internal override {
        // Hoisted: from's hashrate balance is read in Step 1 (Sybil floor) and
        // Step 4 (registeredLp proportional move). Steps 2-3 don't mutate hashrate
        // balance (`_harvest` mints WHALE, not hashrate; bind moves sharedHashrate
        // not balance), so a single read serves both. 0 when from = address(0).
        uint256 fromBal = from == address(0) ? 0 : balanceOf(from);

        // Step 1 — Sybil floor rule. A sender currently at-or-above the valid-invite
        // threshold cannot transfer DOWN to below it. Blocks recycling the same 200-
        // hashrate "slot" across multiple alts (attacker-with-1000 → fund 5 alts to
        // 200 each → transfer back to attacker → repeat with new alts). Without this
        // rule, validDownlines could be inflated unboundedly per stake; with it,
        // the cap is floor(H/200) per stake (each "valid downline" requires real
        // 200 hashrate locked at the alt). Skip mint / burn / DEAD / self.
        if (
            from != address(0) && to != address(0) && from != DEAD && to != DEAD
                && from != to
        ) {
            if (fromBal >= VALID_INVITE_USDT && fromBal - value < VALID_INVITE_USDT) {
                revert TransferBelowValidFloor();
            }
        }

        // Step 2 — auto-harvest BEFORE balance change AND BEFORE bind. Uses pre-update
        // balance and pre-bind referral chain. `_harvest` self-ticks emission
        // internally, so the accumulator is current when it reads.
        //
        // Order matters: bind (Step 3 below) must run AFTER harvest, otherwise alice's
        // accumulated pre-bind static reward would distribute to the just-bound upline
        // via `_distributeDynamic` (which walks `referrer[user]`). The upline only
        // gets dynamic share for static reward EARNED after the bind takes effect.
        //
        // MINT PATH (`from == 0`) skips BOTH harvests — and therefore the tick.
        // This preserves the iron rule (陷阱 17): when settle's `_mint(alice, ΔH)`
        // arrives via WHALE Layer 7a, alice's `userIndex` stays anchored at
        // `staticAcc(T0)`. The post-settle Layer 8 `notifyHarvest` then self-ticks
        // AFTER `super._update` has minted H_new, so alice's next harvest picks up
        // `H_new × (current_acc - staticAcc(T0))` — the full window credited at
        // post-mint balance. (See `T0T1BackdatingProof.t.sol`.)
        //
        // Self-transfer (`to == from`) skips the redundant second harvest call.
        if (from != address(0)) {
            if (from != DEAD) _harvest(from);
            if (to != address(0) && to != DEAD && to != from) _harvest(to);
        }

        // Step 3 — magic-value bind detection (moved AFTER harvest). Two trigger
        // shapes, BOTH gated on `msg.sender == from` (Round-2 fix I-2):
        //   (a) value == REFCODE_AMOUNT — token moves to upline (0.001 hWHALE).
        //   (b) value == 0 — zero-cost marker. No token movement.
        // The `msg.sender == from` gate is REQUIRED for both:
        //   - For value=0: transferFrom passes _spendAllowance (allowance >= 0 always);
        //     without the gate ANY third party could `transferFrom(victim, target, 0)`.
        //   - For REFCODE_AMOUNT: prevents allowance-abuse — a previously-approved
        //     spender could otherwise bind the victim to an arbitrary tree by calling
        //     transferFrom with REFCODE_AMOUNT. Bind is irreversible.
        // Direct `transfer` always sets msg.sender == from. Mirrors WHALE Layer 4 gate.
        //
        // No early return after bind: continue to atomic registeredLp move / super._update
        // / propagate + node status. _tryBindReferral reverts on invalid upline.
        if (
            from != address(0) && to != address(0) && msg.sender == from
                && (value == REFCODE_AMOUNT || value == 0)
        ) {
            _tryBindReferral(from, to);
        }

        // Step 4 — atomic registeredLp move (skip mint, burn, system, self-transfer).
        // Uses `fromBal` hoisted at function top (hashrate balance unchanged by
        // Steps 2-3).
        //
        // CRITICAL `value > 0` GATE: OZ ERC20's `_spendAllowance` allows
        // `transferFrom(victim, attacker, 0)` without any approval (currentAllowance
        // < 0 is always false). Without this gate, the round-up safeguard below
        // would force `lpProp = 1` on every zero-value call, allowing an attacker
        // to drain 1 wei of victim's `registeredLp` per call. After 101 such
        // calls, `_reconcileLp`'s `burnLiquidity > ledger + LP_TOLERANCE (=100)`
        // gate trips and victim's full removeLp DoS-reverts. Gate fixes this:
        // zero-value transfers cannot move the ledger.
        if (
            value > 0 && from != address(0) && to != address(0) && from != to
                && from != DEAD && to != DEAD
        ) {
            if (fromBal > 0) {
                uint256 fromLedger = registeredLp[from];
                uint256 lpProp = (fromLedger * value) / fromBal;
                // Round-up safeguard (Round-1 review C-2 fix): when balance/registered
                // ratio is large (e.g. high WHALE price → ratio ≈ 2 × spotUSDT) and
                // `value` is small, integer division rounds `lpProp` to 0 — leaking
                // hashrate to the receiver without the matching ledger. Force ≥ 1 wei
                // to preserve invariant A (`balance > 0 ⟺ registeredLp > 0`).
                if (lpProp == 0 && fromLedger > 0) lpProp = 1;
                if (lpProp > fromLedger) lpProp = fromLedger; // defensive clamp
                if (lpProp > 0) {
                    unchecked {
                        registeredLp[from] = fromLedger - lpProp;
                        registeredLp[to] += lpProp;
                    }
                }
            }
        }

        super._update(from, to, value);

        // Step 5 — referral propagation + node status (post-update balance).
        //
        // Upline pending rewards are LEFT AS LAZY-ACCRUED. Reasons:
        //   1. The upline's `balanceOf` doesn't change in this tx, so static /
        //      node rewards don't depend on when we settle — same total amount
        //      either now or at the upline's next op / claim.
        //   2. Node status flips are still settled correctly: `_updateNodeStatus`
        //      pays the demoted user inline (via `awardMiningEmission`) before flipping
        //      `isNode` to false, and syncs `userNodeIndex` on promotion.
        //   3. v8 `balanceOf` no longer realtime-computes pending (the v7.x
        //      virtual-credit override was removed in Plan A); proactive harvest
        //      gives no UX benefit on-chain. Frontends that want pending must
        //      eth_call simulate `_harvest` regardless.
        //
        // Saves ~30-60K gas per non-mint transfer (was 2× `_harvest(upline)`
        // calls each ~5-30K depending on chain depth and `_distributeDynamic`).
        if (from != address(0) && from != DEAD) {
            _propagateDown(from, value);
            _updateNodeStatus(from);
        }
        if (to != address(0) && to != DEAD) {
            _propagateUp(to, value);
            _updateNodeStatus(to);
        }
    }

    // ============================================================
    // Internal — Mining (harvest + distribute)
    // ============================================================

    /// @dev Settle `user`'s pending static + node rewards. Calls back into WHALE via
    ///      `awardMiningEmission` (which enforces MINING_MAX and saturates if exceeded).
    ///
    ///      Self-ticks the emission curve before reading accumulators — callers
    ///      don't need to remember to `_tickEmission()` first. Idempotent within
    ///      a block (the tick early-returns if `block.timestamp <= lastEmissionUpdate`),
    ///      so repeated harvest calls in one tx (e.g. `_update` Step 2 harvesting
    ///      both `from` and `to`) only tick once.
    function _harvest(address user) internal {
        if (user == DEAD) return;
        _tickEmission();

        uint256 hash = balanceOf(user);
        uint256 accStatic = staticAccPerShare;

        if (hash > 0) {
            uint256 delta = accStatic - userIndex[user];
            if (delta > 0) {
                uint256 staticReward = (hash * delta) / 1e18;
                if (staticReward > 0) {
                    whale.awardMiningEmission(user, staticReward);
                    emit StaticReward(user, staticReward);
                    _distributeDynamic(user, staticReward);
                }
                userIndex[user] = accStatic;
            }
        } else {
            // First-time entrant: sync userIndex without paying out (no balance to multiply).
            userIndex[user] = accStatic;
        }

        if (isNode[user]) {
            uint256 accNode = nodeAccPerShare;
            uint256 nodeDelta = accNode - userNodeIndex[user];
            if (nodeDelta > 0) {
                uint256 nodeReward = nodeDelta / 1e18;
                if (nodeReward > 0) {
                    whale.awardMiningEmission(user, nodeReward);
                    emit NodeReward(user, nodeReward);
                }
                userNodeIndex[user] = accNode;
            }
        }
    }

    /// @dev 15-generation dynamic distribution.
    ///      Threshold-skipped shares are batched and minted to RefVault — funding the
    ///      one-shot direct-referral reward queue. Sparse trees (early stage) generate
    ///      large hierarchy redirects, so RefVault stays well-funded precisely when
    ///      sell-tax flow is thin. Mature dense trees produce little redirect, by which
    ///      time sell-tax 2% suffices. The unqualified upline still receives nothing —
    ///      `HierarchyBurn` event preserved for indexers.
    ///
    ///      Chain-break (current == 0) preserves prior semantics: tail generations
    ///      after a broken chain are NOT redirected (matches "tree depth" semantics
    ///      vs "specific gen unqualified" — different concepts).
    function _distributeDynamic(address originUser, uint256 staticAmount) internal {
        uint256 dynamicPool = (staticAmount * DYNAMIC_POOL_BPS) / 10_000;
        if (dynamicPool == 0) return;

        address current = referrer[originUser];
        uint256 hierarchyShare;
        uint256 usedShares; // sum of every share consumed by the loop body

        for (uint256 gen; gen < 15;) {
            if (current == address(0)) break;

            uint256 ratio;
            uint256 threshold;
            unchecked {
                ratio = (RATIOS_PACKED >> (gen * 12)) & 0xFFF;
                threshold = (THRESHOLDS_PACKED >> (gen * 4)) & 0xF;
            }
            uint256 share = (dynamicPool * ratio) / 10_000;
            // Short-circuit: ratios are non-increasing (gen0=2500 ≫ gens1-9=625
            // ≫ gens10-14=375). Once `share` truncates to 0 at gen N, all
            // gens N+1..14 also produce 0 → walking the rest only burns SLOADs
            // (referrer chain hop) and emits zero-amount events.
            if (share == 0) break;

            if (validDownlines[current] >= threshold) {
                whale.awardMiningEmission(current, share);
                emit DynamicReward(current, originUser, uint8(gen + 1), share);
            } else {
                unchecked { hierarchyShare += share; }
                emit HierarchyBurn(current, share);
            }
            unchecked { usedShares += share; }

            current = referrer[current];
            unchecked {
                ++gen;
            }
        }

        // Medium-10: any dynamic share that was NOT distributed to the upline
        // chain — origin user has no referrer, chain breaks mid-walk, share
        // truncates to 0 due to rounding, OR the natural rounding residual
        // when all 15 gens walked — gets routed to RefVault. Pre-fix the
        // unwalked tail was burnt with no recipient, leaving
        // `accountedEmission` to count it as realized (since the cap-budget
        // path counts the full 90% static+dynamic when ts > 0). Routing the
        // residual to RefVault keeps `accountedEmission == realized mints`
        // exactly, and gives sparse-tree / orphan users' dynamic share a
        // useful destination (funds the one-shot referral reward queue).
        if (usedShares < dynamicPool) {
            unchecked { hierarchyShare += dynamicPool - usedShares; }
        }

        // Single batched cross-call — saves up to 14× gas vs per-gen mint when
        // many generations are unqualified (sparse-tree common case).
        if (hierarchyShare > 0) {
            whale.awardMiningEmission(refVault, hierarchyShare);
        }
    }

    // ============================================================
    // Internal — Emission (closed-form integrator + accumulator tick)
    // ============================================================

    /// @dev Advance staticAccPerShare / nodeAccPerShare for [lastEmissionUpdate, now].
    ///      Self-tick architecture (v8 Plan A): triggered at top of `_update`, `claim`,
    ///      `notifyHarvest`, `tickEmission`. All paths that observe accumulator state
    ///      tick first, so harvests / propagations always see the up-to-date curve.
    ///
    ///      `circ` reads from PancakeSwap pair reserves directly (WHALE is token1 by
    ///      deploy invariant — see immutable `pair`). This makes emission velocity
    ///      track LP-locked supply rather than total supply, matching the "circulating
    ///      WHALE backed by liquidity" semantic of the original v7.x design.
    ///
    ///      Cap clamp: `_calculateEmission` enforces it via `aRemaining =
    ///      aCum - accountedEmission`. By protocol design `aCum_max = D0 * 1e18 / 2e15
    ///      = D0 * 500 = 41958e18 * 500 = 20_979_000e18 = MINING_MAX` exactly,
    ///      so `emission ≤ aCum - accountedEmission ≤ MINING_MAX - accountedEmission`.
    ///      `whale.awardMiningEmission` independently saturates at MINING_MAX, defense in depth.
    function _tickEmission() internal {
        // Bootstrap on first tick after the v9 openTrading deletion left
        // `lastTickRWHALE == 0` (pair didn't exist at WHALEHashrate construction).
        // The original v8 design initialized `lastTickRWHALE` inside the deleted
        // `notifyTradingOpened` cross-call from `pair.getReserves().reserve1`.
        // Mirror that one-shot init here: when `lastTickRWHALE == 0` AND pair
        // has non-zero WHALE reserve, populate it BEFORE `_previewAccumulators`
        // reads it. Subsequent ticks use the cached lagged value (flash-
        // defense intact — only the first non-empty tick bootstraps).
        if (lastTickRWHALE == 0) {
            (, uint112 r1Boot, ) = pair.getReserves();
            if (r1Boot > 0) lastTickRWHALE = r1Boot;
        }

        (
            uint256 liveStatic,
            uint256 liveNode,
            uint256 emissionDelta,
            bool advanced
        ) = _previewAccumulators();
        if (!advanced) return;
        if (liveStatic != staticAccPerShare) staticAccPerShare = liveStatic;
        if (liveNode != nodeAccPerShare) nodeAccPerShare = liveNode;
        if (emissionDelta > 0) accountedEmission += emissionDelta;
        lastEmissionUpdate = uint64(block.timestamp);
        // High-5: snapshot CURRENT pair rWHALE for the NEXT tick's integration.
        // The just-completed integration used `lastTickRWHALE` (pre-tick value)
        // — manipulation between ticks does not affect the past window's
        // emission. Updating here means the [now, next_tick_time] window will
        // use whatever rWHALE is recorded NOW. Combined with "every pair WHALE
        // transfer self-ticks" (Layer 8 `notifyHarvest`), a flash-loan
        // pump+reverse triggers TWO ticks in same block: tick1 stores pumped
        // rWHALE, tick2 fires at elapsed=0 → 0 emission for the manipulated
        // window. Cross-block manipulation costs sustained price drift,
        // which arbitrageurs erode.
        (, uint112 r1, ) = pair.getReserves();
        if (r1 != lastTickRWHALE) lastTickRWHALE = r1;
    }

    /// @dev Pure-view counterpart to `_tickEmission`: returns the accumulator
    ///      values that WOULD result from a tick at the current block. Used by
    ///      `pendingRewards` to surface live unclaimed totals to wallets without
    ///      mutating storage. `emissionDelta` is the (post-cap) emission this tick
    ///      would write into `accountedEmission`. `advanced` indicates whether
    ///      anything changes (saves the caller two SSTORE checks when nothing to do).
    function _previewAccumulators()
        internal
        view
        returns (uint256 liveStatic, uint256 liveNode, uint256 emissionDelta, bool advanced)
    {
        liveStatic = staticAccPerShare;
        liveNode = nodeAccPerShare;
        if (block.timestamp <= lastEmissionUpdate) return (liveStatic, liveNode, 0, false);

        // Bootstrap fast-path: no users + no nodes ⇒ no accumulator advance possible.
        // Skips `pair.getReserves()` + `_calculateEmission` cross-calls on the empty
        // tree window before the first addLp.
        //
        // High 4 fix (dual-check gate): when there is a pre-open staged user
        // (`whale.lastTransfer() != 0`) AND we are still in the very first window
        // since `openTrading()` (`lastEmissionUpdate == openTime`), DO NOT advance
        // `lastEmissionUpdate`. This preserves the [openTime, T_first_settle]
        // emission window so the next non-empty tick (right after the bootstrap
        // mint) integrates from `openTime`, crediting the bootstrap LP source via
        // its `userIndex = 0` anchor.
        //
        // The dual check distinguishes case A (production bootstrap: deployer's
        // pre-open atomic addLp set `lastTransfer` BEFORE `openTime`) from case B
        // (post-open first staging: `lastTransfer` set by some user AFTER ticks
        // had already advanced `lastEmissionUpdate` past `openTime`). Without the
        // `lastEmissionUpdate == openTime` half, case B's first stager would
        // incorrectly receive a backdated [openTime, settle] window — violating
        // the "mining starts at addLp time, not openTime" iron rule (Trap 17).
        //
        // Outside that pre-open settle window, return `advanced = true` to
        // continue burning empty-tree time per the existing design (no attacker
        // advantage — the burn matches what internal `notifyCredit`-pre-mint
        // ticks would do anyway).
        uint256 ts = totalSupply();
        uint256 nodeCt = totalNodeCount;
        if (ts == 0 && nodeCt == 0) {
            bool preopenStage = lastEmissionUpdate == openTime
                && whale.lastTransfer() != address(0);
            return (liveStatic, liveNode, 0, !preopenStage);
        }

        // High-5: integrate over the past window using `lastTickRWHALE` (rWHALE
        // recorded at the START of this window via the previous tick's
        // snapshot), NOT the current pair reserve. An attacker who pumps
        // `pair.balanceOf(WHALE)` right before calling `tickEmission` cannot
        // retroactively inflate the elapsed window. The current pair reserve
        // is sampled in `_tickEmission` AFTER this call returns, anchoring
        // the NEXT window — which is bounded by the next pair WHALE transfer
        // self-tick (Layer 8 `notifyHarvest`). For the in-block flash-loan
        // case (pump+reverse same block), elapsed between ticks ≈ 0 → 0
        // emission for the manipulated reserve.
        //
        // First-tick: when `lastTickRWHALE == 0` (pre-first-tick state after
        // the v9 openTrading deletion), `_calculateEmission(0)` returns 0
        // and accountedEmission isn't advanced. This is intentional flash-
        // defense: the storage path stays strict. The view-only
        // `_dailyEmission` falls back to live pair reserves for display
        // (see that function). Production deploys should trigger one
        // post-LP user op to populate `lastTickRWHALE` via the natural empty-
        // tree advance — Deploy.s.sol or the deployer's initial LP add
        // accomplishes this implicitly.
        emissionDelta = _calculateEmission(uint256(lastTickRWHALE));
        if (emissionDelta == 0) return (liveStatic, liveNode, 0, true);

        uint256 staticPart = emissionDelta * EMIT_STATIC_PCT / 100;
        uint256 nodePart = emissionDelta * EMIT_NODE_PCT / 100;

        // Per-tick emission breakdown:
        //   staticPart (50%): credited to staticAccPerShare; users collect their
        //                     share at harvest time → realized when ts > 0.
        //   dynamicShare (40%): NOT directly credited anywhere — realized lazily
        //                       when users `_harvest` their static_reward, which
        //                       triggers `_distributeDynamic(user, staticReward)`
        //                       minting additional `staticReward × 80%` to the
        //                       upline chain. So static + dynamic = 90% of emission
        //                       realizes whenever ts > 0.
        //   nodePart (10%): credited to nodeAccPerShare; nodes collect at harvest
        //                   → realized when nodeCt > 0.
        //
        // accountedEmission must track ONLY what will actually mint, otherwise
        // the cap clamp `aRemaining = aCum - accountedEmission` consumes budget
        // for shares that get burnt with no recipient. Specifically: when
        // `nodeCt == 0` the 10% node share has no denominator and is permanently
        // lost. Counting it against the cap would let MINING_MAX go under-spent
        // by ~10% of the no-node-window emission. Recompute `emissionDelta` to
        // include only the realized portions so cap progresses with realized
        // mints, and total emission can asymptotically reach MINING_MAX.
        uint256 effectiveEmission;
        if (ts > 0 && staticPart > 0) {
            liveStatic += (staticPart * 1e18) / ts;
            // staticPart + dynamicShare = emissionDelta - nodePart = 90% × emissionDelta
            effectiveEmission += emissionDelta - nodePart;
        }
        if (nodeCt > 0 && nodePart > 0) {
            liveNode += (nodePart * 1e18) / nodeCt;
            effectiveEmission += nodePart;
        }
        emissionDelta = effectiveEmission;
        advanced = true;
    }

    /// @dev Closed-form emission integrator for the [lastEmissionUpdate, now] window.
    ///      Daily emission = `circ × 160 bps × 0.998^t`, capped against the cumulative
    ///      A-curve `D0 × (1 - 0.998^(t+1)) / 0.002`. Cap headroom uses
    ///      `accountedEmission` (debt) — NOT `whale.totalEmitted()` (paid). Critical 3
    ///      fix: under B>A regime the unharvested accumulator debt would otherwise
    ///      let repeated ticks issue O(N²) excess until first harvest realized it.
    ///
    ///      Gas note: PRBMath `pow998` runs `exp(t·ln(0.998))` (~5-10K gas / call).
    ///      Adjacent values differ by exactly `× 998 / 1000` in fixed-point (the
    ///      iterative-approximation rounding diverges by ≤1 wei vs a direct
    ///      `pow998(t+1)`, immaterial for emission integration). So we compute
    ///      pow998 ONCE per distinct t and derive the rest by multiplication.
    function _calculateEmission(uint256 circ) internal view returns (uint256) {
        uint256 startTime = lastEmissionUpdate;
        uint256 endTime = block.timestamp;
        if (endTime <= startTime) return 0;

        uint256 t_start = (startTime - openTime) / 1 days;
        uint256 t_end = (endTime - openTime) / 1 days;

        uint256 totalB;
        uint256 decay_t_end; // shared; needed for the cap-clamp `× 998 / 1000` derivation

        if (t_start == t_end) {
            decay_t_end = PowMath.pow998(t_start);
            uint256 dailyB = circ * 160 * decay_t_end / 10_000 / 1e18;
            totalB = dailyB * (endTime - startTime) / 1 days;
        } else {
            uint256 nextDayBoundary = openTime + (t_start + 1) * 1 days;
            uint256 dayStartOfTEnd = openTime + t_end * 1 days;

            uint256 decay_start = PowMath.pow998(t_start);
            uint256 dailyB_start = circ * 160 * decay_start / 10_000 / 1e18;
            uint256 headSegment = dailyB_start * (nextDayBoundary - startTime) / 1 days;

            decay_t_end = PowMath.pow998(t_end);
            uint256 dailyB_end = circ * 160 * decay_t_end / 10_000 / 1e18;
            uint256 tailSegment = dailyB_end * (endTime - dayStartOfTEnd) / 1 days;

            uint256 middleSegment;
            if (t_end > t_start + 1) {
                // Reuse decay_start instead of `pow998(t_start + 1)` — saves one
                // ~5-10K gas exp() call per cross-day tick.
                uint256 decay_first_full = decay_start * 998 / 1000;
                if (decay_first_full > decay_t_end) {
                    uint256 decayDiff = decay_first_full - decay_t_end;
                    middleSegment = circ * 160 * decayDiff * 500 / 10_000 / 1e18;
                }
            }

            totalB = headSegment + middleSegment + tailSegment;
        }

        // Reuse decay_t_end instead of `pow998(t_end + 1)` — saves one ~5-10K gas
        // exp() call on EVERY tick (single-day common path included).
        uint256 decay_t_end_plus_1 = decay_t_end * 998 / 1000;
        uint256 aCum = D0 * (1e18 - decay_t_end_plus_1) / 2e15;
        uint256 accounted = accountedEmission;
        uint256 aRemaining = aCum > accounted ? aCum - accounted : 0;

        return totalB < aRemaining ? totalB : aRemaining;
    }

    /// @dev View-only daily emission projection. Mirrors `_calculateEmission`'s
    ///      cap clamp: `min(B-curve daily, aCum - accountedEmission)`.
    ///      Gas: one `pow998` call total (vs two pre-opt) — same `× 998 / 1000`
    ///      derivation as `_calculateEmission`.
    function _dailyEmission(uint256 t) internal view returns (uint256) {
        uint256 decay_t = PowMath.pow998(t);
        uint256 decay_t_plus_1 = decay_t * 998 / 1000;
        uint256 aCum = D0 * (1e18 - decay_t_plus_1) / 2e15;
        uint256 accounted = accountedEmission;
        uint256 aRemaining = aCum > accounted ? aCum - accounted : 0;

        // High-5: project using lagged `lastTickRWHALE`, matching what an actual
        // tick at this moment would integrate. Frontend daily-emission view
        // therefore shows the un-manipulable projection.
        //
        // First-tick bootstrap (mirrors `_previewAccumulators`): when
        // `lastTickRWHALE == 0` (pre-first-tick state), fall back to live pair
        // reserves so the view reflects emission accurately right after
        // initial liquidity is added.
        uint256 tickRWHALE = uint256(lastTickRWHALE);
        if (tickRWHALE == 0) {
            (, uint112 currentR1, ) = pair.getReserves();
            tickRWHALE = uint256(currentR1);
        }
        uint256 b = tickRWHALE * 160 / 10_000 * decay_t / 1e18;

        return b < aRemaining ? b : aRemaining;
    }

    // ============================================================
    // Internal — Referral propagation + node status
    // ============================================================

    /// @dev Increment `ref.sharedHashrate += amount` and update validDownlines on
    ///      cross-up. Called when `user`'s balance INCREASES by `amount` (mint OR
    ///      transfer-in). Round-1 fix C-1: this NO LONGER fires the one-shot referral
    ///      reward — that fires only from `notifyCredit` (LP-backed credit path) to
    ///      block Sybil-via-transfer drains. validDownlines is the live counter (must
    ///      track every cross-up regardless of source); reward queueing is the one-shot.
    function _propagateUp(address user, uint256 amount) internal {
        address ref = referrer[user];
        if (ref == address(0) || ref == DEAD) return;

        uint256 oldShared = sharedHashrate[ref];
        uint256 newShared;
        unchecked { newShared = oldShared + amount; sharedHashrate[ref] = newShared; }

        // Gate `_updateNodeStatus` on possible status change (F14):
        //   - Promotion needs `sharedHashrate` to cross UP through NODE_PERF_USDT.
        //     `balanceOf(ref)` doesn't change in this function (only `user`'s does),
        //     so a promotion is only reachable via this cross.
        //   - Demotion via balance change is handled by Step 5 `_updateNodeStatus(user)`
        //     when ref's own balance changes — not by this propagation path.
        //   - `|| isNode[ref]` is defense-in-depth: if ref is currently a node and
        //     state is somehow inconsistent (should never happen), still re-validate.
        // Saves ~3-5K gas per transfer when no threshold crossing happens (common case).
        bool sharedCrossedUp = oldShared < NODE_PERF_USDT && newShared >= NODE_PERF_USDT;
        if (sharedCrossedUp || isNode[ref]) {
            _updateNodeStatus(ref);
        }

        uint256 hashAfter = balanceOf(user);
        uint256 hashBefore;
        unchecked {
            hashBefore = hashAfter - amount;
        }
        // Live validDownlines: increment on every cross-up (mint or transfer-in).
        // Reward queue NOT triggered here — see notifyCredit for LP-backed reward path.
        if (hashBefore < VALID_INVITE_USDT && hashAfter >= VALID_INVITE_USDT) {
            unchecked {
                validDownlines[ref]++;
            }
        }
    }

    /// @dev Decrement `ref.sharedHashrate -= amount`. Called when `user`'s balance
    ///      DECREASES by `amount`. Reverts SharedHashrateUnderflow if the running total
    ///      goes negative — that signals a credit/debit pairing bug, never silent-zero.
    function _propagateDown(address user, uint256 amount) internal {
        address ref = referrer[user];
        if (ref == address(0) || ref == DEAD) return;

        uint256 oldShared = sharedHashrate[ref];
        if (oldShared < amount) revert SharedHashrateUnderflow();
        uint256 newShared;
        unchecked { newShared = oldShared - amount; sharedHashrate[ref] = newShared; }

        // Gate `_updateNodeStatus` on possible status change (F14):
        //   - Demotion via shared needs `sharedHashrate` to cross DOWN through
        //     NODE_PERF_USDT. ref's `balanceOf` doesn't change here.
        //   - `|| isNode[ref]` is the safety net — covers the rare case where ref
        //     is a node and shared dropped within the qualifying band but external
        //     state suggests we should re-check.
        bool sharedCrossedDown = oldShared >= NODE_PERF_USDT && newShared < NODE_PERF_USDT;
        if (sharedCrossedDown || isNode[ref]) {
            _updateNodeStatus(ref);
        }

        uint256 hashAfter = balanceOf(user);
        uint256 hashBefore;
        unchecked {
            hashBefore = hashAfter + amount;
        }
        if (hashBefore >= VALID_INVITE_USDT && hashAfter < VALID_INVITE_USDT) {
            if (validDownlines[ref] > 0) {
                unchecked {
                    validDownlines[ref]--;
                }
            }
        }
    }

    /// @dev Re-evaluate node qualification. Settles pending node reward on demotion.
    ///
    ///      DELIBERATELY does NOT self-tick. Reads `nodeAccPerShare` directly
    ///      from storage so the iron-rule (Trap 17) backdating semantics hold
    ///      for promotion via addLp settle: when alice's addLp at T0 is
    ///      settled at T1 by another user's op, the recursive WHALEHashrate
    ///      `_update` mint path SKIPS Step 2 `_harvest` (because `from == 0`),
    ///      so `_tickEmission` has NOT run yet when this reaches Step 5
    ///      `_updateNodeStatus(upline)`. upline's `userNodeIndex` anchors at
    ///      PRE-tick `nodeAccPerShare`. Then WHALE's outer Layer 8 `notifyHarvest`
    ///      ticks emission, capturing the `[T0_addLp, T1_settle]` window's
    ///      node-reward share into the accumulator delta. upline collects
    ///      that window in their next harvest — promotion backdates to the
    ///      economic moment (alice's T0), not the bookkeeping settle T1.
    ///
    ///      The non-mint callers (transfer / burn) all run Step 2 `_harvest`
    ///      first, which ticks emission, so no staleness exists by the time
    ///      Step 5 reaches here. The ONLY entry that previously bypassed both
    ///      paths was `bindReferral(upline)` external — that entry now ticks
    ///      explicitly at its top before reaching `_executeBind`.
    function _updateNodeStatus(address user) internal {
        if (user == DEAD) return;

        bool wasNode = isNode[user];
        bool qualifies =
            balanceOf(user) >= NODE_LP_USDT && sharedHashrate[user] >= NODE_PERF_USDT;

        if (!wasNode && qualifies) {
            isNode[user] = true;
            unchecked {
                totalNodeCount++;
            }
            userNodeIndex[user] = nodeAccPerShare;
            emit NodeAdded(user);
        } else if (wasNode && !qualifies) {
            // Settle pending node reward before demotion.
            uint256 delta = nodeAccPerShare - userNodeIndex[user];
            if (delta > 0) {
                uint256 reward = delta / 1e18;
                if (reward > 0) whale.awardMiningEmission(user, reward);
            }
            unchecked {
                totalNodeCount--;
            }
            isNode[user] = false;
            emit NodeRemoved(user);
        }
    }

    // ============================================================
    // Internal — Bind helpers
    // ============================================================

    function _executeBind(address from, address to) internal {
        referrer[from] = to;

        // Back-credit existing balance: if `from` had hashrate before binding (LP added
        // first, bind later), that pre-bind hashrate was never credited to any upline's
        // sharedHashrate. A future debit would underflow `to`'s sharedHashrate. Catch up
        // at bind time — same logic as v7.x `_executeBind`.
        uint256 existingHash = balanceOf(from);
        if (existingHash > 0) {
            unchecked {
                sharedHashrate[to] += existingHash;
            }
            _updateNodeStatus(to);
            // Live validDownlines: increment if back-credited user already qualifies
            // (this is the only place this fires for the bind path — _propagateUp
            // is not triggered by binding because no token movement occurs).
            // Round-1 fix C-1: reward queue NOT fired on bind back-credit, only on
            // LP-backed credit (notifyCredit). Sybil class: attacker.transfer(alt, H)
            // then alt.bindReferral(ref) would otherwise queue a reward without a real
            // LP commitment behind alt's balance.
            if (existingHash >= VALID_INVITE_USDT) {
                unchecked {
                    validDownlines[to]++;
                }
            }
        }
        // v8: emit ReferrerBound directly. Replaces v7.x's `RefVault.notifyBind` cross-call
        // (RefVault.notifyBind was a pure event-relay with no state change — eliminating
        // the cross-call removes one onlyController-vault dependency).
        emit ReferrerBound(from, to);
    }

    /// @dev Bind attempt with three-way semantics:
    ///   - Already bound (or `from` is a system address): silent no-op → returns false.
    ///     Caller treats the magic-value transfer as a regular harvest-trigger / token
    ///     transfer.
    ///   - Invalid upline (self-bind / system upline / orphan upline): REVERT.
    ///     Surfaces the failure visibly to the user's wallet — bind is irreversible
    ///     so silent failure would corrupt user's perceived state.
    ///   - Valid bind: executes `_executeBind`, returns true.
    ///
    ///     Medium-8 trade-off: hashrate-side magic-value transfer (Step 3 of
    ///     this contract's `_update`) and the explicit `bindReferral(upline)`
    ///     entry both PROPAGATE the InvalidBind revert. The WHALE-side magic-value
    ///     transfer (Layer 14 in `WHALE.sol`) wraps `notifyMagicBind` in try/catch
    ///     so a 0-value WHALE transfer to an orphan target satisfies ERC20 probe
    ///     expectations without a revert; the inner revert remains observable in
    ///     trace metadata.
    function _tryBindReferral(address from, address to) internal returns (bool) {
        // Silent no-op cases (caller continues normal _update flow):
        //  - `referrer[from] != 0` — user already bound; treat transfer as harvest /
        //                            regular transfer, not a bind attempt.
        //  - `from == DEAD`        — defensive; structurally unreachable since DEAD
        //                            cannot initiate transfers (no signer).
        //  - `from == to`          — self-transfer (harvest trigger pattern).
        //  - `to == DEAD`          — user is burning, not binding.
        if (referrer[from] != address(0)) return false;
        if (from == DEAD) return false;
        if (from == to) return false;
        if (to == DEAD) return false;

        // Bind ATTEMPT (unbound user transferring to a non-system EOA): strict
        // validation. Revert on orphan upline so user's wallet shows the failure
        // visibly rather than silently-failed bind.
        if (referrer[to] == address(0)) revert InvalidBind();

        _executeBind(from, to);
        return true;
    }

    // (v8.x: `_isSystemAddress` was a 1-line helper `addr == DEAD` — fully inlined
    // at all callsites. Previous v7.x implementation also filtered pair / whale /
    // this / 4 vaults; analysis showed those are grief-class with no profit-
    // extraction path, so they're accepted as known limits. DEAD remains the only
    // filter because tokens at DEAD are by convention "burned" — harvesting them
    // would mint WHALE permanently inaccessible.)
}
