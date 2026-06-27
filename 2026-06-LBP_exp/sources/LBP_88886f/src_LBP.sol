// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPancakePair} from "./interfaces/IPancakePair.sol";
import {IPancakeFactory} from "./interfaces/IPancakeFactory.sol";
import {SqrtMath} from "./libs/SqrtMath.sol";
import {BurnVault} from "./BurnVault.sol";
import {RefVault} from "./RefVault.sol";
import {PolVault} from "./PolVault.sol";
import {IFomoVault} from "./interfaces/IFomoVault.sol";
import {HashrateRegistry} from "./HashrateRegistry.sol";
import {LBPHashrate} from "./LBPHashrate.sol";

/**
 * @title LBP — Little Boy Plus (v8.0)
 * @notice Immutable ERC-20 token. v8 architecture externalizes hashrate / mining /
 *         referral state into a sibling contract `LBPHashrate (hLBP)`. LBP keeps:
 *
 *           - ERC-20 token state (pure: no virtual-credit balanceOf override)
 *           - Sell / buy / dynamic tax routing
 *           - Method-B add/remove-LP detection (stage / verify / settle pipeline)
 *           - TWAP cascade + 30-day peak tracker (sell-tax base price)
 *           - FOMO trigger (Layer 12) — forwards to FomoVault.notifyTrade
 *           - Active burn hook (Layer 11) — forwards to BurnVault.triggerReward
 *           - POL trigger via 0.001 LBP magic transfer to FomoVault
 *           - openTrading lifecycle gate (key-hash unlock)
 *           - Mining emission decay + cap enforcement at the `mintReward` boundary
 *
 *         Externalized to LBPHashrate (callable via `hashrate.notify*` cross-call):
 *
 *           - userHashrate / totalHashrate / sharedHashrate / validDownlines
 *           - Mining accumulator (staticAccPerShare / nodeAccPerShare) + harvest
 *           - 15-generation dynamic distribution
 *           - Referral tree (`referrer`, bind / `_executeBind` / one-shot reward)
 *           - Node qualification + count
 *           - LP commitment ledger (`registeredLp`, atomic with hashrate balance)
 *
 *         Cross-contract trust model: LBPHashrate's `notify*` endpoints are
 *         `onlyLBP`; LBP's `mintReward` is `onlyHashrate`.
 *         The recursion `LBP._update → hashrate.notifyHarvest → hashrate._harvest →
 *         lbp.mintReward → LBP._mint → super._update(0, to, amt)` terminates at
 *         Layer 1 (`from == address(0)` short-circuit) — no pipeline re-entry.
 *
 * === Manipulation defence ===
 *
 *   (a) Method-B LP tracking (v8.x): `_stagePending` (Layer 8c) writes
 *       `lastTransfer / pendingMintFee / pendingExpectedUserLp` for ANY
 *       `to == pair` LBP transfer that has a non-zero predicted user LP
 *       (`usdtBalance > rUSDT`, i.e. the addLp pattern). Non-addLp paths
 *       (pure sells, dust transfers without donation) hit `expectedLp == 0`
 *       and `_clearStage()` instead — both eliminating any prior stale stage
 *       and writing none. `_inferPendingHashrate` reads POST-mint reserves
 *       at settle (`pair.getReserves()` + `pair.totalSupply()`); within a
 *       single Router atomic addLp tx no third party can interleave between
 *       Layer 8c stage and pair.mint, so post-mint reserves match the user's
 *       intended hashrate.
 *
 *       FOMO entry, by contrast, fires AT STAGE (not settle) and is gated
 *       on `msg.sender == PANCAKE_ROUTER && tx.origin == from && from.code.length == 0`.
 *       Stage-time firing keeps the FOMO timer in lock-step with the user's
 *       commit moment (settle in a later tx may run after the timer would
 *       have expired). Router-only gating restricts FOMO to canonical-router
 *       LP-adders; manual-atomic addLp users still receive hashrate credit
 *       at settle but do not enter the lottery.
 *   (b) The dynamic sell tax (5-20%, base 5% + dynamic up to 15%) makes any
 *       pump-addLp-dump round-trip net-negative. Combined with LP-share derivation,
 *       unbalanced donations are diluted into the pool and do not count as hashrate.
 *
 * === Known trust assumptions / UX constraints ===
 *
 * 1. PancakeSwap V2 Factory `feeTo` is assumed non-malicious. Method-B LP tracking
 *    predicts `_mintFee` based on the factory's current `feeTo()` value; divergence at
 *    execution would mis-estimate by the feeTo LP delta. On BSC PancakeSwap, `feeTo` is
 *    controlled by a trusted multisig and changes extremely rarely.
 * 2. Manual-atomic addLp (single-tx `usdt.transfer + lbp.transfer + pair.mint(self)`)
 *    is supported for hashrate / LP credit but does NOT confer FOMO entry — only
 *    Router-mediated addLp does. Manual-split-tx (LP-leg and pair.mint in different
 *    transactions) remains exposed to dust frontrun (documented in CLAUDE.md
 *    "addLp 原子性" known limit).
 */
contract LBP is ERC20, ERC20Permit {
    // ============================================================
    // Constants
    // ============================================================

    uint256 public constant TOTAL_SUPPLY = 21_000_000 * 1e18;
    uint256 private constant INITIAL_SUPPLY = 21_000 * 1e18;
    /// @dev MINING_MAX = TOTAL_SUPPLY - INITIAL_SUPPLY. `private` to avoid a derived-value
    ///      getter; consumers can compute from the two above. Mirrored in LBPHashrate
    ///      where the emission curve lives — both ends saturate against this cap.
    uint256 private constant MINING_MAX = TOTAL_SUPPLY - INITIAL_SUPPLY;

    // Tax rates (bps)
    uint256 private constant BUY_TAX_BPS = 100;           // 1%
    uint256 private constant SELL_TAX_BASE_BPS = 500;     // 5% (base)
    /// @dev Dynamic-part cap: +15% over the 5% base. Internal — no public getter needed.
    uint256 private constant SELL_TAX_DYN_CAP_BPS = 1_500;
    /// @dev Slope: each 1% deviation below base adds 0.3% tax (30 bps / 100 bps).
    uint256 private constant SELL_TAX_SLOPE_NUM = 30;
    uint256 private constant SELL_TAX_SLOPE_DEN = 100;

    /// @dev Buy tax split: BUY_POL_BPS goes to POL, remainder (= 10000 - BUY_POL_BPS) to FOMO.
    uint256 private constant BUY_POL_BPS = 5_000;

    /// @dev Active-burn min-entry threshold: 1 USDT-equivalent at SPOT. Cap eligible
    ///      burn at 10 LBP per call so reward cannot exceed 13 LBP per single burn.
    uint256 private constant ACTIVE_BURN_MIN_USDT = 1e18;       // 1 USDT
    uint256 private constant ACTIVE_BURN_MAX_LBP = 10 * 1e18;   // 10 LBP eligible per call

    /// @dev Magic-value transfer to `fomoVault` triggers `PolVault.flushPolForUser`.
    ///      Caller receives 0.5% of the POL buffer (capped at 10 LBP) as flush
    ///      incentive; the 0.001 LBP donation joins the FOMO pool.
    uint256 public constant POL_TRIGGER_AMOUNT = 1 * 10 ** 15;

    /// @dev Magic-value referral binding via LBP transfer. Mirrors `LBPHashrate.REFCODE_AMOUNT`.
    ///      User UX: `lbp.transfer(upline, REFCODE_AMOUNT)` binds caller to upline if gates
    ///      pass (see `_tryMagicBind`). 0.0011 LBP moves to upline as a side effect.
    uint256 public constant REFCODE_AMOUNT = 11 * 10 ** 14;

    // Tolerance for Layer 7a verify (mint-fee predictor drift). 100 wei absorbs
    // any 1-2 wei drift without enabling economically meaningful evasion.
    uint256 private constant LP_TOLERANCE = 100;

    // (Emission split moved to LBPHashrate in v8: 50% static / 10% node / 40% dynamic.
    // The 40% dynamic emerges as 80% of each user's static reward inside
    // `_distributeDynamic`. Cap enforcement still funnels through `mintReward` here.)

    // Sell-tax base slice (20/40/40 dev/burn/ref):
    uint256 private constant SELL_BASE_DEV_PCT = 20;
    uint256 private constant SELL_BASE_BURN_PCT = 40;
    // Sell-tax dynamic slice (40/40/20 fomo/pol/burn):
    uint256 private constant SELL_DYN_FOMO_PCT = 40;
    uint256 private constant SELL_DYN_POL_PCT = 40;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ============================================================
    // Errors
    // ============================================================
    error InvalidLBPAddress();
    error InvalidRegistry();
    error ZeroAddress();
    /// @dev `openTrading(bytes)` rejected — provided key's hash does not match
    ///      the `openingHash` baked at deploy time.
    error InvalidOpeningKey();
    error OnlyPolVault();
    /// @dev `mintReward` callable only by the wired
    ///      LBPHashrate contract.
    error OnlyHashrate();
    error AlreadyOpened();
    error NotYetOpened();
    error BnbNotAccepted();
    /// @dev Plan B Part 2: pre-staged expected LP from `addLp` doesn't match the
    ///      reconstructed total LP delta observed at the first `_update` after the mint.
    error LpMintShortfall();
    /// @dev Plan A (hard-revert): `pair.burn(to)` where `to`'s LP ledger doesn't admit
    ///      the burn — `to` is not the LP source, so the burn is a hijack attempt or a
    ///      V1 "alt cash-out". Caller must burn to the LP source whose `registeredLp`
    ///      exceeds their real pair balance.
    error InvalidBurn();
    /// @dev Active burn (`transfer(DEAD, amount)`) exceeds the per-call cap of
    ///      `ACTIVE_BURN_MAX_LBP` (10 LBP). Users wanting to destroy more must split
    ///      into multiple txs.
    error ActiveBurnTooLarge();
    /// @dev Direct transfers to the LBP contract itself are forbidden. With FOMO
    ///      extracted to `fomoVault`, LBP no longer uses self-balance as the pool —
    ///      accidental donations would be unrecoverable. Users intending to fund
    ///      FOMO must send to `fomoVault` directly.
    error SelfTransferForbidden();

    // ============================================================
    // Events
    // ============================================================

    /// @dev Emits `tax` and `taxBps`. Slice details (basePart, dynPart, and 6
    ///      destination amounts) are deterministic from `tax + taxBps + on-chain
    ///      constants`, so indexers can reconstruct them.
    event SellTax(address indexed seller, uint256 tax, uint256 taxBps);
    // Hashrate / referral / mining events (HashrateCredited, HashrateDebited,
    // StaticReward, NodeReward, DynamicReward, HierarchyBurn, NodeAdded, NodeRemoved)
    // moved to LBPHashrate — emitted from `notifyCredit` / `_harvest` / etc.
    // ReferrerBound and ReferralRewardTriggered remain on RefVault.

    // ============================================================
    // Immutables
    // ============================================================

    /// @dev keccak256 of an arbitrary opening secret known only to the deployer.
    ///      `openTrading(bytes calldata key)` accepts only `key` such that
    ///      `keccak256(key) == openingHash`.
    bytes32 internal immutable openingHash;
    address public immutable devWallet;
    IERC20 public immutable USDT;
    IPancakeFactory public immutable PANCAKE_FACTORY;
    address public immutable pair;
    BurnVault public immutable burnVault;
    RefVault public immutable refVault;
    PolVault public immutable polVault;
    IFomoVault public immutable fomoVault;
    /// @notice v8 sibling: holds hashrate balance, mining accumulator, referral tree,
    ///         node state, and the LP commitment ledger. Cross-contract calls flow
    ///         L↔H via the `notify*` (LBP→hashrate) and `mintReward`
    ///         (hashrate→LBP) endpoints. The one-shot referral reward decision
    ///         is returned synchronously from `notifyCredit` for LBP to fire
    ///         `refVault.triggerReward` directly — no separate hashrate→LBP path.
    LBPHashrate public immutable hashrate;
    /// @dev Canonical PancakeSwap V2 Router on BSC mainnet. v8 retains the v7.0
    ///      Router-only stage-write gate for Method-B's Layer 8c.
    address public immutable PANCAKE_ROUTER;

    // ============================================================
    // Storage
    // ============================================================

    // Slot-packed: tradingOpened (1B) + openTime (8B) + cachedFeeOn (1B) + 22B free.
    // (`lastEmissionUpdate` moved to LBPHashrate alongside the emission curve in v8 Plan A.)
    bool public tradingOpened;
    uint64 public openTime;
    /// @notice Cached `factory.feeTo() != address(0)` state. Layer 7a verify gate
    ///         routes through one of two settle classifications based on this flag.
    /// @dev `refreshFeeToCache()` is permissionless — anyone can re-sync the cache.
    bool public cachedFeeOn;

    // ---------- Method-B LP tracking (unchanged primitive) ----------
    // All Method-B addLp staging fields populate atomically in `_stagePending`
    // (Layer 8c), consume in `_settlePendingLpAdd` / `_verifyAndSettle` (Layer 7a),
    // and clear together inside `_settlePendingLpAdd` after settle completes.
    //
    //   `lastTransfer`           — credit recipient (last LP-source).
    //   `pendingMintFee`         — predicted feeTo LP delta.
    //   `pendingExpectedUserLp`  — accumulator for C2 piggyback verify check.
    //
    // (Stage-time reserve snapshot deleted — settle uses current `getReserves()`
    // at settle moment. Trade-off: opens a self-inflation surface where alice
    // contributes unbalanced (USDT-heavy) addLp to inflate her own hashrate
    // proportional to her pool share. Bounded by 2L/R ratio (per dollar lost,
    // gain 2L/R USDT-eq of hashrate); only profitable when alice controls a
    // significant fraction of the pool. Accepted for code simplicity — Router-
    // only addLp + balanced ratios make exploitation hard in practice.)
    uint256 internal lastTotalLp;
    uint256 internal lastKLast;
    // slot-packed: lastTransfer(20B) + pendingMintFee(12B)
    address public lastTransfer;
    uint96 internal pendingMintFee;

    // ---------- Mining state ----------
    // `totalEmitted` is no longer a storage variable — it's derived from
    // `totalSupply() - INITIAL_SUPPLY`. The invariant holds because:
    //   1. The constructor mints `INITIAL_SUPPLY` once.
    //   2. The ONLY other `_mint` path is `mintReward` (gated `onlyHashrate`),
    //      which represents pure mining emission.
    //   3. There is NO `_burn` in v8 LBP — active burns route to DEAD via
    //      `super._update`, leaving totalSupply intact.
    // See `totalEmitted()` view below + `mintReward` for cap enforcement.
    // (Plan A: `lastEmissionUpdate` + `_calculateEmission` + accumulator
    // advance migrated to LBPHashrate. LBP retains only the cap clamp here.)

    // Slot 12: pendingExpectedUserLp (12B) + 20B free.
    uint96 internal pendingExpectedUserLp;

    // ---------- TWAP (3-level cascade per window, unchanged from v1) ----------
    struct TwapSnapshot {
        uint224 priceCumulative;
        uint32 timestamp;
    }
    TwapSnapshot internal snapshot30min_old;
    TwapSnapshot internal snapshot30min_mid;
    TwapSnapshot internal snapshot30min_new;
    TwapSnapshot internal snapshot30d_old;
    TwapSnapshot internal snapshot30d_mid;
    TwapSnapshot internal snapshot30d_new;

    // ---------- Sell-tax peak tracking ----------
    //
    // Same packing / semantics as v7.x.
    //   Slot A: peakTwap30d (28B) + peak30minDayIdx (4B)                  = 32B
    //   Slot B: cachedPeakMax (24B) + cachedPeakDay (4B) + peak30minLastDay (4B) = 32B
    //   Slots C-AF: peak30minDaily[0..29] (32B each)
    uint224 public peakTwap30d;
    uint32 internal peak30minDayIdx;
    uint192 internal cachedPeakMax;
    uint32 internal cachedPeakDay;
    uint32 internal peak30minLastDay;
    uint224[30] internal peak30minDaily;

    // NOTE: no userLp / userHashrate / totalHashrate / userIndex / userNodeIndex /
    // isNode / totalNodeCount / staticAccPerShare / nodeAccPerShare / referrer /
    // sharedHashrate / validDownlines / rewardTriggered. All migrated to LBPHashrate.

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyHashrate() {
        if (msg.sender != address(hashrate)) revert OnlyHashrate();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    /// @param _registry Pre-deployed HashrateRegistry holding all 6 contract addresses
    ///                  (predicted via off-chain CREATE2 computation). LBP reads them
    ///                  here as immutable storage. The cycle "LBP needs hashrate_addr,
    ///                  hashrate needs LBP_addr, vaults need LBP_addr" is broken
    ///                  because `_registry` is deployed via REGULAR CREATE (nonce-based
    ///                  address, independent of args) BEFORE LBP. LBPHashrate and
    ///                  vaults are deployed AFTER LBP at the predicted CREATE2
    ///                  addresses. See `src/HashrateRegistry.sol` for the full chain.
    constructor(
        bytes32 _openingHash,
        address _devWallet,
        address _receiver,
        IERC20 _usdt,
        IPancakeFactory _factory,
        HashrateRegistry _registry,
        address _router
    )
        ERC20("Little Boy Plus", "Little Boy Plus")
        ERC20Permit("Little Boy Plus")
    {
        // Round-3 P1-3: reject empty-key openingHash. Empty bytes hash to
        // 0xc5d2…fa0e7e (keccak256("")) — if the deploy script accidentally
        // passes an unset env var that fell through to default empty bytes,
        // anyone could `openTrading("")` and bypass the access control. On an
        // immutable contract, this would brick deployment forever. Checked
        // BEFORE the LBP-address invariant so the empty-key error surfaces
        // even when the salt also fails the token1-ordering check.
        if (
            _openingHash == bytes32(0)
                || _openingHash == 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        ) revert InvalidOpeningKey();

        // L-1 router sanity (also constructor-arg-only — fire early, before the
        // LBP-address invariant, so test harnesses with arbitrary salts surface the
        // intended error rather than the address-invariant tripwire).
        if (_router == address(0) || _router.code.length == 0) revert ZeroAddress();

        // Medium-9: reject zero / self / pair as devWallet.
        //   - address(0): sell-tax base-dev slice would route to address(0),
        //     which OZ ERC20's _update treats as a real burn → totalSupply
        //     drops below INITIAL_SUPPLY → mintReward's cap clamp underflows
        //     (now defensively guarded, but rejecting upstream is cleaner).
        //   - address(this): tax flowing to LBP itself enters virtual-credit
        //     accounting paths that aren't designed for tax recipient.
        //   - pair: tax flowing to pair would silently arbitrage the buffer
        //     and break the LP backing invariants.
        // _receiver and _usdt are validated implicitly by the LBP-address
        // ordering check below + the receiver self-bind in the registry path.
        if (_devWallet == address(0) || _devWallet == address(this)) revert ZeroAddress();

        if (address(this) <= address(_usdt)) revert InvalidLBPAddress();

        openingHash = _openingHash;
        devWallet = _devWallet;
        USDT = _usdt;
        PANCAKE_FACTORY = _factory;
        // L-1 (v7.0): router sanity already checked above (moved earlier in v8).
        PANCAKE_ROUTER = _router;

        pair = _factory.createPair(address(this), address(_usdt));

        // Medium-9 (continued): final devWallet check — reject pair as well.
        // Tax routed to pair would silently inflate AMM reserves and break
        // invariants. Pair address is only known post-createPair.
        if (_devWallet == pair) revert ZeroAddress();

        // Read all 6 wired addresses from the registry. They were predicted off-chain
        // to match the (yet-to-be-deployed) CREATE2 addresses; the deploy script
        // verifies the match post-deploy via sanity asserts.
        //
        // Defense-in-depth: reject zero-address wiring at construction. Without this,
        // a malformed registry could poison LBP with vault=0 (silent fund loss on
        // sell-tax routing) or hashrate=0 (every notify call reverts → Method-B brick).
        address _hashrate = _registry.hashrate();
        address _burnVault = _registry.burnVault();
        address _refVault = _registry.refVault();
        address _polVault = _registry.polVault();
        address _fomoVault = _registry.fomoVault();
        if (
            _hashrate == address(0) || _burnVault == address(0) || _refVault == address(0)
                || _polVault == address(0) || _fomoVault == address(0)
        ) {
            revert InvalidRegistry();
        }
        hashrate = LBPHashrate(_hashrate);
        burnVault = BurnVault(_burnVault);
        refVault = RefVault(_refVault);
        polVault = PolVault(_polVault);
        fomoVault = IFomoVault(_fomoVault);

        _mint(_receiver, INITIAL_SUPPLY);

        // v8.x: receiver self-loop is installed by LBPHashrate's OWN constructor
        // (replaces former cross-call to `hashrate.bindReceiver(_receiver)`).
        // The receiver is now passed to LBPHashrate as a constructor arg,
        // anchoring it atomically with hashrate construction.

        // Snapshot factory.feeTo() state. Used by Layer 7a verify gate.
        cachedFeeOn = _factory.feeTo() != address(0);

        // TWAP cascade snapshots intentionally NOT anchored — pre-mint price is
        // undefined. Layer 13 auto-seeds on the first post-mint `_update`.
    }

    /// @notice Re-read `factory.feeTo()` state into `cachedFeeOn`. Permissionless.
    function refreshFeeToCache() external {
        cachedFeeOn = PANCAKE_FACTORY.feeTo() != address(0);
    }

    // ============================================================
    // Trading control
    // ============================================================

    /// @dev openTrading is intentionally minimal: ONLY flips the trading flag and
    ///      sets the emission/peak anchors. Pre-open contributors (deployer / pre-trading
    ///      LP holders) are staged via Method-B and settled by the first post-open
    ///      `_update` whose Layer 7a outer gate fires.
    function openTrading(bytes calldata key) external {
        if (keccak256(key) != openingHash) revert InvalidOpeningKey();
        if (tradingOpened) revert AlreadyOpened();

        tradingOpened = true;
        uint64 nowU64 = uint64(block.timestamp);
        openTime = nowU64;

        // Cross-call: hand the emission anchor to LBPHashrate (Plan A — emission
        // curve / accumulator advance lives there now).
        hashrate.notifyTradingOpened(nowU64);

        // FOMO clock anchor: rebase `lastUpdate` to openTrading time.
        fomoVault.rebaseLastUpdate();

        // Peak tracker day anchor.
        uint32 today = uint32(block.timestamp / 1 days);
        peak30minLastDay = today;
        cachedPeakDay = today;
    }

    // ============================================================
    // BNB rejection
    // ============================================================

    receive() external payable {
        revert BnbNotAccepted();
    }

    fallback() external payable {
        revert BnbNotAccepted();
    }

    // ============================================================
    // Hashrate-gated callbacks (LBP-side surface for cross-contract call)
    // ============================================================

    /// @notice Called by LBPHashrate when a user's pending mining reward materializes.
    ///         Enforces the global emission cap.
    /// @dev    Saturates if cap exceeded — does NOT revert. Lets LBPHashrate's
    ///         `_harvest` proceed gracefully past the cap (subsequent calls mint 0).
    ///         The accumulator advance lives in LBPHashrate's `_tickEmission`
    ///         (v8 Plan A); realized mints saturate here independently.
    function mintReward(address to, uint256 amount) external onlyHashrate {
        // v8 derives `emitted` from totalSupply (single source of truth).
        // `_mint` below auto-updates totalSupply — no manual SSTORE needed.
        //
        // Robust cap clamp:
        //   1. `totalSupply()` MAY (in degenerate states) be < INITIAL_SUPPLY
        //      if real burns to address(0) occurred. With v8's constructor
        //      validating `devWallet != address(0)`, every code-path that
        //      could route LBP to the zero address is closed at deploy time.
        //      We still guard the subtraction defensively — saturate to 0
        //      rather than underflow-revert. A revert here would brick every
        //      `_harvest` (cascade: every transfer / claim / settle that
        //      touches mining), permanently disabling the protocol.
        //   2. Compute `remaining = MINING_MAX - emitted` safely; if cap
        //      already reached or exceeded, mint nothing and return.
        //   3. Clamp `amount` to `remaining`. No `emitted + amount` addition
        //      (which could overflow in extreme inputs).
        uint256 supply = totalSupply();
        uint256 emitted = supply > INITIAL_SUPPLY ? supply - INITIAL_SUPPLY : 0;
        if (emitted >= MINING_MAX) return;
        uint256 remaining;
        unchecked { remaining = MINING_MAX - emitted; }
        if (amount > remaining) amount = remaining;
        if (amount == 0) return;
        _mint(to, amount);
    }

    /// @notice Cumulative LBP minted via mining emission so far. Derived from
    ///         `totalSupply() - INITIAL_SUPPLY` (no separate storage in v8).
    /// @dev    Cast to uint128 preserves the v7.x ABI signature (auto-generated
    ///         getter when `totalEmitted` was a `uint128 public` storage variable).
    ///         The cast is safe — value bounded by `MINING_MAX = 21M − 21K LBP`,
    ///         well under `type(uint128).max`. Underflow guard mirrors
    ///         `mintReward` in case a degenerate state ever pushes `totalSupply`
    ///         below `INITIAL_SUPPLY`.
    function totalEmitted() public view returns (uint128) {
        uint256 supply = totalSupply();
        return supply > INITIAL_SUPPLY ? uint128(supply - INITIAL_SUPPLY) : 0;
    }

    // (queueReferralReward DELETED — replaced by `notifyCredit` return-value pattern.
    // Reward computation + RefVault queue happens inline in `_settlePendingLpAdd`.)

    // ============================================================
    // System address + pair helpers
    // ============================================================

    // (v8.x: `_isSystemAddress` helper deleted. Layer 2 explicit short-circuit
    // covers `this / burnVault / refVault / polVault / fomoVault / hashrate`;
    // pair handled separately by Layer 2.5 + `from != pair` guards; DEAD has no
    // signer so cannot initiate transfers. _reconcileLp's gate 1 (`ledger == 0`)
    // catches any system-address `to` since system addresses never accumulate
    // `registeredLp` (no Router-mediated addLp path from a vault / pair / etc).)

    /// @dev Returns `(lbpReserve, usdtReserve, blockTimestampLast)`. LBP is token1 by
    ///      constructor invariant.
    function _getReserves() internal view returns (uint112 rLBP, uint112 rUSDT, uint32 ts) {
        (uint112 r0, uint112 r1, uint32 t) = IPancakePair(pair).getReserves();
        return (r1, r0, t);
    }

    function _spotPrice() internal view returns (uint256) {
        (uint112 rLBP, uint112 rUSDT,) = _getReserves();
        if (rLBP == 0) return 0;
        return uint256(rUSDT) * 1e18 / uint256(rLBP);
    }

    // ============================================================
    // _update hook — protocol heart
    //
    // v8 layer flow (numbers reflect runtime order):
    //   1  → 1.5 → 2  → 2.5 → 3   (preflight + system-address shorts)
    //   5  → 6                    (pre-trading guard + reserves snapshot)
    //   7a (verify pending addLp + settle via hashrate.notifyCredit)
    //   8  (auto-harvest both sides; emission tick lives inside hashrate.notifyHarvest)
    //   7b (pair-burn reconcile + hashrate.notifyDebit)
    //   8c → 8d                   (staging maintenance + LP snapshot)
    //   13 (TWAP cascade rotation — runs both pre-open and post-open)
    //   ── post-open only branch (gated on tradingOpen) ──
    //   8e  (peakTwap30d advance, pre-Layer-9)
    //   9 → 10 (classify + tax + execute)
    //   11 (active-burn hook)
    //   12 (FOMO timer)
    //   ── post-pipeline (always runs) ──
    //   14 (magic-value referral binding via LBP transfer)
    //   15 (POL flush trigger via ≥ POL_TRIGGER_AMOUNT to fomoVault, EOA-only)
    // ============================================================

    function _update(address from, address to, uint256 value) internal override {
        // Layer 1: mint/burn — bypass the pipeline.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Layer 1.5: prevent transfers TO this contract.
        if (to == address(this)) revert SelfTransferForbidden();

        // Layer 2: system-address exemption (from side). Includes hashrate (v8).
        if (
            from == address(this) || from == address(burnVault) || from == address(refVault)
                || from == address(polVault) || from == address(fomoVault)
                || from == address(hashrate)
        ) {
            super._update(from, to, value);
            return;
        }

        // Layer 2.5: pair as from + value=0 short-circuit.
        //
        // OZ ERC20 `_spendAllowance` does NOT check allowance when value == 0, so anyone
        // can call `lbp.transferFrom(pair, _, 0)` for free. Without this guard, value=0
        // transfers from pair would run the entire pipeline — exposing free triggers for
        // Layer 7a verify, Layer 8 mining, Layer 8e peakTwap30d, Layer 13 cascade rotation.
        if (from == pair && value == 0) {
            super._update(from, to, 0);
            return;
        }

        // Layer 3: pair uninitialised guard.
        //
        // Bootstrap `to == pair` (first-ever LBP transfer to pair before pair.mint
        // creates LP): record `lastTransfer = from` so the NEXT op (TS > 0) settles
        // this user's full LP credit via Layer 7a `_settlePendingLpAdd`. Layer 8c's
        // staging math would div-by-zero here (newTs = 0, reserves = 0).
        uint256 totalLpNow = IPancakePair(pair).totalSupply();
        if (totalLpNow == 0) {
            super._update(from, to, value);
            // Bootstrap LP source. Layer 2 already filtered 6 system-address
            // `from` cases; pair excluded by `from != pair`; DEAD cannot signer.
            if (to == pair && from != pair) {
                lastTransfer = from;
            }
            return;
        }

        // (Layer 14 (magic-value referral binding) runs at the END of _update —
        // see below. Notify-only with try/catch so the bind tx still flows through
        // Layer 7a settle / Layer 8 harvest / TWAP / peak / route, doubling as a
        // "claim" trigger.)

        // (Layer 15 (POL flush trigger) runs at the END of _update — see below.
        // Notify-only with no early-return so the trigger tx flows through Layer 8
        // harvest first, letting the caller materialize pending mining rewards in
        // the same tx as the flush.)

        // Cache `tradingOpened` once.
        bool tradingOpen = tradingOpened;

        // Layer 5: pre-open restriction. Block from=pair (swap-buy / pair.burn / pair.skim
        // flows pulling LBP out of pair). Allow to=pair so deployer can seed initial
        // liquidity between constructor and openTrading() via Router atomic addLiquidity.
        if (!tradingOpen && from == pair) revert NotYetOpened();

        // (v8.x: Layer 5.5 active-burn cap moved into `_onActiveBurn` itself —
        // single source of truth for active-burn gating + reward, exercised at
        // Layer 11. Trade-off: revert path now wastes ~30K extra gas going through
        // Layers 6-10 first, but normal-path users never hit it.)

        // Layer 6: read pair state once. Reserves snapshot serves Layer 6 (spot),
        // Layer 8 (mining base), Layer 13 (priceCumulative extrapolation), and is
        // packed into a uint256 for `_verifyAndSettle` to avoid stack pressure.
        uint112 rLBP;
        uint112 rUSDT;
        uint256 spotPriceNow;
        uint256 currentCum;
        {
            uint32 _ts;
            (rLBP, rUSDT, _ts) = _getReserves();
            spotPriceNow = rLBP > 0 ? uint256(rUSDT) * 1e18 / uint256(rLBP) : 0;
            currentCum = _currentPriceCumulative(rLBP, rUSDT, _ts);
        }

        // Skip `pair.kLast()` cross-call (~2.3K gas) on pure user-to-user
        // transfers with no pending stage: pair didn't mint/burn this tx, so
        // kLast hasn't changed; no settle gate fires (lastTransfer == 0); no
        // _stagePending (to != pair). Layer 8d snapshot update is a no-op
        // when kLastChanged=false, so omitting the SLOAD is harmless.
        uint256 kLastNow;
        bool kLastChanged;
        if (from == pair || to == pair || lastTransfer != address(0)) {
            kLastNow = IPancakePair(pair).kLast();
            kLastChanged = kLastNow != lastKLast;
        }

        // Cached USDT.balanceOf(pair), set in Layer 8c (to == pair) and reused by
        // Layer 9's `_splitSellAndLp`.
        uint256 usdtBalance;

        // Two-branch burn detection — see `_detectBurn`.
        bool isBurnNow;
        uint256 burnLiquidity;
        if (from == pair) {
            (isBurnNow, burnLiquidity) = _detectBurn(value, rUSDT, totalLpNow);
        }

        // Layer 7a: verify pending mint expectation, then settle via cross-call to
        // LBPHashrate. Logic shared with `_resolvePendingBeforePolOperation` via
        // `_verifyAndSettle`.
        //
        // Settle trigger OR's three signals:
        //   1. `kLastChanged` — fires when factory.feeTo != 0 AND a mint/burn happened.
        //   2. `totalLpNow != lastTotalLp` — protocol-independent.
        //   3. `!cachedFeeOn` — feeTo=0 fallback for exact-offset C2 piggyback.
        if (
            (kLastChanged || totalLpNow != lastTotalLp || !cachedFeeOn)
            && lastTransfer != address(0)
        ) {
            _verifyAndSettle(
                totalLpNow,
                burnLiquidity,
                /*realizeFee=*/ true,
                from,
                kLastChanged,
                rUSDT,
                spotPriceNow,
                currentCum
            );
        }

        // Layer 8: auto-harvest BOTH `from` and `to`. v8 Plan A — accumulator advance
        // lives inside LBPHashrate; `notifyHarvest` self-ticks the emission curve at
        // its top, then materializes pending static + node rewards via callback to
        // `mintReward`. Idempotent within a block (subsequent ticks short-circuit on
        // `block.timestamp <= lastEmissionUpdate`), so calling notifyHarvest twice
        // here only ticks once.
        //
        // ORDER NOTE: Layer 8 runs AFTER Layer 7a settle. This implements an
        // intentional "stage-time backdating" — alice's userIndex is synced at
        // PRE-advance during settle's Step 2 harvest, so her next harvest captures
        // the [stage, settle] window's accumulator delta. Staged users get fair
        // earning power for the time their LP was committed but settle hadn't yet
        // fired. Trade-off: a freshly-promoted node also backdates into the elapsed
        // period (gets a slice of pre-promotion node emission). Accepted as part of
        // the same fairness semantics.
        //
        // Skip harvest when `from == pair` (buy / burn): pair holds no hashrate by
        // construction. Same skip for `to == pair` (sell / addLp), `to == from`
        // (self-transfer double-harvest), and address(0) endpoints. notifyHarvest
        // is `nonReentrant` — recursion via mintReward → _mint → super._update(0,...)
        // → Layer 1 short-circuit cannot re-enter.
        if (tradingOpen) {
            if (from != pair) hashrate.notifyHarvest(from);
            if (to != pair && to != from) {
                hashrate.notifyHarvest(to);
            }
        }

        // Layer 7b: reconcile LP ledger vs real pair balance on burn. Cross-call
        // view reads `hashrate.registeredLp(to)` (defense-in-depth fast pre-filter);
        // authoritative debit happens in `hashrate.notifyDebit`.
        if (isBurnNow) {
            _reconcileLp(to, burnLiquidity);
        }

        // (v8.x: Layer 8b removed. The K-change-triggered stage clear it provided
        // is unnecessary in the Router-only model — atomic Router.addLiquidity
        // means stage and settle are bracketed by the same tx with no intervening
        // K change, and the settle path itself clears stage at its end.)

        // Layer 13: TWAP cascade rotation — runs in BOTH pre-open AND post-open.
        // HOISTED before Layer 8c so non-Router stage's tax-aware expectedLp
        // computation reads the same TWAP cascade state Layer 9 will use.
        _maybeUpdateTwapSnapshots(currentCum);

        // Layer 8e: peak tracker advance BEFORE Layer 8c's tax-aware expectedLp
        // (non-Router) AND Layer 9's tax calc both read `_currentSellTaxBps`.
        // Hoisted with Layer 13 so all three paths (Layer 8c stage, Layer 9 tax,
        // and external callers) see consistent peak / TWAP state.
        if (tradingOpen) {
            _updatePeakTwap(currentCum);
        }

        // Layer 8c: stage fresh pending on user→pair LBP transfer.
        // Extracted to `_stagePending` for via-ir stack budget.
        if (to == pair) {
            usdtBalance = _stagePending(value, kLastNow, totalLpNow, rLBP, rUSDT, from, spotPriceNow, tradingOpen);
        }

        // Layer 8d: LP state snapshot.
        if (totalLpNow != lastTotalLp) lastTotalLp = totalLpNow;
        if (kLastChanged) lastKLast = kLastNow;

        if (tradingOpen) {
            // Layer 9 + 10: classify + tax + route.
            (bool isBuy, bool isSell, uint256 sellPart) = _classifyAndRoute(
                from, to, value, rLBP, rUSDT, spotPriceNow, usdtBalance, isBurnNow
            );

            // Layer 11: active burn hook.
            // `from != pair` replaces `!_isSystemAddress(from)` — Layer 2 already
            // filtered the system set; pair is the only remaining system from-source.
            if (to == DEAD && from != pair) {
                _onActiveBurn(from, value, spotPriceNow);
            }

            // Layer 12: forward trade context to FomoVault. Wrapped in try/catch —
            // FomoVault is a side-effect (timer / pool bookkeeping); a vault revert
            // here would brick every buy / sell. Fail-open keeps trading alive
            // even if FomoVault state is unexpectedly bad.
            if (isBuy || isSell) {
                try fomoVault.notifyTrade(isBuy, isSell, value, sellPart, spotPriceNow) {} catch {}
            }
        } else {
            // Pre-trading: pipeline already ran Layers 1-8d (Method-B staging + LP
            // snapshot) and Layer 13 (cascade rotation). No tax, no FOMO, no active-burn.
            super._update(from, to, value);
        }

        // Layer 14: magic-value referral binding via LBP transfer.
        //
        // Two paths, both gated on `msg.sender == from` to prevent allowance-based
        // force-binds (`transferFrom(victim, attackerUpline, 0/REFCODE)` with a
        // pre-granted allowance ≥ REFCODE_AMOUNT — bind is irreversible, so a
        // yield wrapper / DEX router with max approval could otherwise capture
        // victim into the attacker's subtree):
        //   (a) value == REFCODE_AMOUNT (0.0011 LBP) — token moves to upline.
        //   (b) value == 0 — zero-cost bind marker.
        //
        // POSITION (post-pipeline): bind runs AFTER Layer 7a settle / Layer 8
        // harvest / Layer 9 transfer, so the same tx can serve as a claim trigger
        // (transfer-0 → harvest pending mining) AND a bind. Settle / harvest see
        // the pre-bind tree, but `_executeBind` back-credits alice's resulting
        // hashrate to upline atomically — equivalent end state for upline.
        //
        // Soft-fail bind via try/catch (Medium-8 trade-off):
        //   - `notifyMagicBind` REVERTS InvalidBind on orphan upline / self-bind
        //     / system endpoint. The revert remains observable in trace
        //     metadata (wallet UIs commonly surface "internal call reverted"
        //     warnings) — but does NOT propagate, so the outer ERC20 transfer
        //     completes normally.
        //   - Critical for ERC20 compliance: wallets, accounting integrations,
        //     aggregators, and test harnesses commonly probe with 0-value
        //     transfers expecting them to never revert. Hard-revert here would
        //     break those flows for any unbound user (orphan target = revert).
        //   - Users wanting EXPLICIT bind feedback (visible failure on orphan)
        //     must use `hashrate.bindReferral(upline)` direct entry, which
        //     still propagates the revert. Same applies to hashrate-side
        //     magic-value transfers (`hashrate.transfer(orphan, 0/REFCODE)`)
        //     which propagate as well — hLBP is a protocol-specific token
        //     where strict bind semantics outweigh probe-compatibility.
        if (msg.sender == from && (value == 0 || value == REFCODE_AMOUNT)) {
            try hashrate.notifyMagicBind(from, to) returns (bool) {} catch {}
        }

        // Layer 15: POL flush trigger via magic-value transfer
        // to fomoVault. Wallet `Send` of ≥ POL_TRIGGER_AMOUNT (0.001 LBP) to
        // `fomoVault`:
        //   1. The transferred LBP joins the FOMO pool (donation, already done
        //      by super._update inside Layer 9 above).
        //   2. `flushPolForUser(from)` runs: caller receives ≤0.5% of the POL
        //      buffer in LBP.
        //
        // POSITION (post-pipeline): runs AFTER Layer 8 harvest, so a user with
        // pending mining rewards but zero hot LBP balance can use the same tx
        // to (a) harvest mining rewards into balance, (b) auto-transfer the
        // 0.001 LBP donation, (c) trigger the POL flush + receive the caller
        // reward. No early return — the transfer-side super._update has already
        // moved the value to fomoVault via Layer 9.
        //
        // Trigger is EOA-only and direct-transfer-only:
        //   - `from == msg.sender` blocks `transferFrom` paths so the trigger
        //     can't be piggybacked onto an arbitrary user's allowance flow.
        //   - `msg.sender.code.length == 0` blocks ordinary contract callers
        //     (MEV bots, batch routers) from harvesting the caller reward.
        //   - `tx.origin == msg.sender` blocks the constructor-bypass loophole:
        //     during a contract's `constructor`, `EXTCODESIZE(self) == 0`
        //     because the runtime bytecode hasn't been written yet — so the
        //     code.length check alone would let a one-shot CREATE2 contract
        //     fire the trigger from inside its constructor. `tx.origin` is
        //     the original tx signer (always an EOA pre-EIP-7702; with 7702
        //     the signer EOA may have code, in which case the code.length
        //     check excludes them anyway). Combined: only EOAs in their own
        //     direct calls trigger the reward.
        //
        // The donation itself (super._update value transfer) still goes through
        // for any caller — only the flush-and-reward leg is gated.
        if (
            to == address(fomoVault)
                && value >= POL_TRIGGER_AMOUNT
                && from == msg.sender
                && msg.sender.code.length == 0
                && tx.origin == msg.sender
        ) {
            polVault.flushPolForUser(from);
        }
    }

    // ============================================================
    // LP tracking — Method B (predict-then-realize)
    // ============================================================

    function _predictMintFee(
        uint256 kLast,
        uint256 totalSupply_,
        uint112 reserve0,
        uint112 reserve1
    ) internal view returns (uint256) {
        if (kLast == 0) return 0;

        // Fast-path: cached factory.feeTo state. Saves ~2.5K gas (cross-call to
        // factory.feeTo) on every Layer 8c stage when feeTo is known off.
        // `refreshFeeToCache` is permissionless — anyone can re-sync; cache
        // staleness only manifests if feeTo flips and nobody refreshes (existing
        // documented limit).
        if (!cachedFeeOn) return 0;

        if (reserve0 == 0 || reserve1 == 0) return 0;

        uint256 rootK = SqrtMath.sqrt(uint256(reserve0) * uint256(reserve1));
        uint256 rootKLast = SqrtMath.sqrt(kLast);
        if (rootK <= rootKLast) return 0;

        uint256 numerator = totalSupply_ * (rootK - rootKLast) * 8;
        uint256 denominator = rootK * 17 + rootKLast * 8;
        return numerator / denominator;
    }

    /// @dev Layer 8c staging. Records the pending mint-fee prediction + user
    ///      contribution snapshot, pre-computes expectedLp via PancakeV2's
    ///      `min(l0, l1)` formula (using POST-tax LBP for non-Router callers
    ///      to mirror Layer 9's force-sell), and fires FOMO entry for
    ///      Router-only addLp. Returns `usdtBalance` (cached for Layer 9).
    function _stagePending(
        uint256 value,
        uint256 kLastNow,
        uint256 totalLpNow,
        uint112 rLBP,
        uint112 rUSDT,
        address from,
        uint256 spotPriceNow,
        bool tradingOpened_
    ) internal returns (uint256 usdtBalance) {
        usdtBalance = USDT.balanceOf(pair);

        // Compute `expectedLp` BEFORE writing any stage. Both Router and non-Router
        // callers run the same logic — discrimination happens via `usdtBalance >
        // rUSDT`. A real `pair.mint` requires the USDT side to already be in the
        // pair excess. Pure swaps / sells / dust transfers leave `usdtBalance ==
        // rUSDT` at this hook moment, so `expectedLp` resolves to 0 and we hit
        // `_clearStage()` below.
        //
        // CRITICAL 2 fix: `expectedLp == 0` means NOT an addLp pattern. Skip ALL
        // stage writes AND clear any prior stage. Without this, a stale
        // `lastTransfer` could phantom-credit a FUTURE mint by an unrelated user.
        //
        // Non-Router atomic addLp (M-1 fix): a manual-atomic addLp user
        // (`usdt.transfer + lbp.transfer + pair.mint(self)` in a single tx) needs
        // their own `lbp.transfer` to write the stage; otherwise the stage is
        // empty (or worse, set by a stale Router-staged attacker) and their LP
        // mint either earns no hashrate or is hijacked. We compute the post-tax
        // LBP that will reach pair (Layer 9 force-sells non-Router), so
        // `expectedLp` matches the actual LP `pair.mint` will produce.
        //
        // Sell-with-donation residue: an attacker pre-donating USDT and then
        // doing a Router swap WILL write a stage with `expectedLp > 0` (the
        // Layer 9 lpPart classification can't distinguish swap-with-donation
        // from real addLp at hook time). Such stages persist briefly but get
        // cleared by the next from=pair op (Layer 7a settle's degenerate path
        // when `actualLpDelta == 0`) or overwritten by any subsequent legitimate
        // addLp. This is the v7.0 sell-tax-bypass known limit's tail; v8.1
        // LBPRouter will close both via `msg.sender == LBPRouter` gating.
        //
        // Trade-off: LBP-first Router `addLiquidity(LBP, USDT, ...)` (USDT NOT
        // arrived yet at LBP transfer hook) loses credit. Frontends MUST use
        // USDT-first ordering — already documented requirement in CLAUDE.md.
        uint256 predicted = _predictMintFee(kLastNow, totalLpNow, rLBP, rUSDT);
        if (predicted > type(uint96).max) predicted = type(uint96).max;

        // For non-Router post-trading transfers, Layer 9 will force-sell `value`
        // with the dynamic sell-tax rate. Predict the same rate here (Layer 8e
        // has been hoisted above so `_currentSellTaxBps` reads the same peak
        // state Layer 9 sees) so `valueIn` matches the LBP that actually lands
        // in pair. Mirrors Layer 9's initial+post-spot recheck verbatim.
        uint256 valueIn = value;
        if (tradingOpened_ && msg.sender != PANCAKE_ROUTER) {
            uint256 sellTaxBps = _currentSellTaxBps(spotPriceNow);
            {
                uint256 denom = uint256(rLBP) + value;
                uint256 postSpot = denom == 0
                    ? 0
                    : spotPriceNow * uint256(rLBP) / denom * uint256(rLBP) / denom;
                uint256 postTax = _currentSellTaxBps(postSpot);
                if (postTax > sellTaxBps) sellTaxBps = postTax;
            }
            uint256 tax = value * sellTaxBps / 10_000;
            unchecked { valueIn = value - tax; }
        }

        uint256 expectedLp;
        if (usdtBalance > rUSDT) {
            // Same `min(l0,l1)` formula as PancakeV2's pair.mint. Post-transfer
            // LBP balance is `super.balanceOf(pair) + valueIn` (super._update has
            // not run yet at this hook moment); for non-Router, `valueIn` is the
            // post-tax fraction that survives Layer 9's force-sell.
            uint256 lbpBalanceAfter = super.balanceOf(pair) + valueIn;
            uint256 lbpExcess = lbpBalanceAfter > uint256(rLBP) ? lbpBalanceAfter - uint256(rLBP) : 0;
            if (lbpExcess > 0) {
                uint256 newTs = totalLpNow + predicted;
                uint256 l0 = (usdtBalance - rUSDT) * newTs / uint256(rUSDT);
                uint256 l1 = lbpExcess * newTs / uint256(rLBP);
                expectedLp = l0 < l1 ? l0 : l1;
            }
        }

        if (expectedLp == 0) {
            // Not an addLp pattern. ACTIVELY CLEAR any stale stage: in the rare
            // case where Layer 7a's `_settlePendingLpAdd` early-returned without
            // clearing (e.g., predicted mintFee >= totalDelta yields userLpDelta
            // == 0), a stale `lastTransfer` could phantom-credit a FUTURE mint
            // by an unrelated user. Clearing on every "no addLp intent" call
            // closes that surface.
            _clearStage();
            return usdtBalance;
        }

        // Confirmed addLp pattern. Stage normally. Both Router and non-Router
        // write `pendingExpectedUserLp` based on (post-tax for non-Router)
        // expectedLp — the Layer 7a verify gate then catches piggyback C2
        // (intermediate burn / skim that reduces actualLpDelta below expected)
        // for both paths.
        //
        // feeTo-off stale-stage DDoS: when `cachedFeeOn=false`, the verify gate
        // fires unconditionally on every from=pair op. A stage written without
        // a follow-up mint (swap-with-donation pattern, attempted by anyone)
        // causes subsequent buys to revert `LpMintShortfall` until the next
        // legitimate Router atomic addLp clears the stage. This is a
        // pre-existing v6.8.1 documented limit: BSC mainnet PancakeSwap keeps
        // `feeTo` non-zero permanently, so `cachedFeeOn=true` and the DDoS
        // path is unreachable. The keeper-bot mitigation (refreshFeeToCache
        // on factory.setFeeTo(0)) covers the rare admin-flip scenario.
        //
        // In feeTo-on mode (BSC normal), `kLastChanged` is the verify trigger,
        // and only `pair.mint` / `pair.burn` change kLast — pure swaps don't.
        // So a stage written with no subsequent mint never fires verify;
        // natural defense via the kLast signal.
        // OVERWRITE — repeated dust stages don't accumulate. uint96 truncation safe.
        pendingMintFee = uint96(predicted);
        lastTransfer = from;
        pendingExpectedUserLp = uint96(expectedLp);

        // FOMO entry fires HERE (at stage), not at settle, so the FOMO timer
        // reflects the user's commit moment instantly. Settle runs in a later
        // tx and may be after the timer would have expired, breaking FOMO's
        // commit-then-wait semantics.
        //
        // Gates (defense-in-depth):
        //   - `tradingOpened`: pre-open addLps (deployer / ICO bootstrap) are
        //     not part of the lottery.
        //   - `msg.sender == PANCAKE_ROUTER`: only canonical-router LP-adders
        //     enter the lottery. Manual-atomic addLp users still get hashrate
        //     and LP credit (above) but do not enter FOMO. This restricts the
        //     vault state mutation to a single trusted entry point.
        //   - `tx.origin == from`: blocks contracts that wrap Router calls
        //     (`from = wrapper contract`, `tx.origin = end-user EOA` — fails).
        //   - `from.code.length == 0`: blocks 7702-delegated EOAs and
        //     constructor-time contracts (the `tx.origin == from` check
        //     already covers constructor-bypass; this is defense-in-depth).
        //
        // Wrapped in try/catch — FOMO bookkeeping must never brick addLp.
        if (
            tradingOpened_
                && msg.sender == PANCAKE_ROUTER
                && tx.origin == from
                && from.code.length == 0
        ) {
            // fomoEqv = predicted user share of post-mint USDT reserve.
            // Equivalent to `expectedLp × usdtBalance / (TS_now + feeMint + expectedLp)`.
            // Matches the settle-time `userLpDelta × useRUsdt / stageTs` formula
            // up to the predicted-vs-realized drift (≤ 1-2 wei for Router atomic).
            uint256 newTsPostMint = totalLpNow + predicted + expectedLp;
            uint256 fomoEqv;
            unchecked {
                fomoEqv = expectedLp * usdtBalance / newTsPostMint;
            }
            try fomoVault.notifyLpAdd(from, fomoEqv) {} catch {}
        }
    }

    /// @dev Two-branch burn detection used by Layer 6 / Layer 7b.
    ///
    /// (a) USDT balance signal: `pair.burn` transfers USDT out BEFORE the LBP leg.
    /// (b) totalLp strict decrease: covers net-negative piggyback where attacker's
    ///     burn exceeds alice's mint.
    ///
    /// burnLiquidity uses max of two formulas for exactness:
    ///   (a) `value × totalLpNow / (balanceLBP - value)` — algebraically inverts
    ///       pair.burn's `amount1 = L × balance1 / TS` to recover L.
    ///   (b) `lastTotalLp - totalLpNow` — exact when no concurrent mint.
    ///
    /// Exact-offset piggyback evades both signals here; Layer 7a `_verifyAndSettle`
    /// catches it via `pendingExpectedUserLp` shortfall revert.
    function _detectBurn(uint256 value, uint112 rUSDT, uint256 totalLpNow_)
        internal
        view
        returns (bool isBurnNow, uint256 burnLiquidity)
    {
        uint256 lastTotalLp_ = lastTotalLp;
        uint256 usdtBalance = USDT.balanceOf(pair);
        isBurnNow = (usdtBalance < uint256(rUSDT)) || (totalLpNow_ < lastTotalLp_);
        if (isBurnNow) {
            uint256 balanceLBP = super.balanceOf(pair);
            uint256 fromFormula;
            if (balanceLBP > value) {
                fromFormula = value * totalLpNow_ / (balanceLBP - value);
            }
            uint256 fromDelta = lastTotalLp_ > totalLpNow_ ? lastTotalLp_ - totalLpNow_ : 0;
            burnLiquidity = fromFormula > fromDelta ? fromFormula : fromDelta;
        }
    }

    /// @dev Layer 7a / POL-callback shared settlement. Wraps the cross-call to
    ///      LBPHashrate's `notifyCredit` with current pair reserves passed through.
    ///      v8.x simplification: BOTH bootstrap and steady-state branches use
    ///      post-mint `currentRUsdt` + post-mint `totalLpNow_`. Stage-time
    ///      snapshot deleted — see storage block comment for the trade-off
    ///      (unbalanced-addLp self-inflation surface, bounded by pool fraction).
    function _settlePendingLpAdd(
        uint256 totalLpNow_,
        uint256 lastTotalLp_,
        bool realizeFee,
        uint112 currentRUsdt,
        uint256 spotPrice,
        uint256 currentCum
    ) internal {
        address lastTransfer_ = lastTransfer;
        if (lastTransfer_ == address(0)) return;
        if (totalLpNow_ <= lastTotalLp_) {
            // No LP increase visible at settle time. Stage is stale (a Layer 8c
            // write paired with a prior op whose mint already accounted into
            // `lastTotalLp` via Layer 8d snapshot). Clear it so subsequent
            // `_verifyAndSettle` calls don't trip `LpMintShortfall` against the
            // dangling `pendingExpectedUserLp`.
            _clearStage();
            return;
        }

        uint256 totalDelta = totalLpNow_ - lastTotalLp_;
        uint256 realizedMintFee;
        if (lastTotalLp_ == 0) {
            // Bootstrap: PancakeV2 permanently mints MINIMUM_LIQUIDITY=1000 to
            // address(0) before alice's user-LP mint. Subtract so the
            // `registeredLp(u) == 0 ⟺ hashrate.balanceOf(u) == 0` invariant holds.
            realizedMintFee = 1000;
        } else if (realizeFee) {
            uint256 pmf = uint256(pendingMintFee);
            if (pmf > 0) realizedMintFee = pmf > totalDelta ? totalDelta : pmf;
        }
        uint256 userLpDelta = totalDelta > realizedMintFee ? totalDelta - realizedMintFee : 0;
        uint256 useRUsdt = uint256(currentRUsdt);
        uint256 stageTs = totalLpNow_;
        if (userLpDelta == 0 || useRUsdt == 0 || stageTs == 0) {
            // Degenerate path: predicted feeTo mint consumed entire delta
            // (pmf >= totalDelta), or pair has empty USDT reserves, or
            // post-mint TS is zero. None should be reachable in a healthy
            // pair, but defensive cleanup prevents downstream
            // `LpMintShortfall` reverts if the path ever fires (e.g., via
            // an unexpected mint-fee accrual edge case).
            _clearStage();
            return;
        }

        // Cross-call into LBPHashrate. notifyCredit:
        //   - increments `registeredLp[user]`
        //   - mints hashrate (= 2 × userLpDelta × useRUsdt / stageTs)
        //   - propagates upline state via Step 4 of its _update
        //   - RETURNS (refToReward, hashrateUsed) for one-shot reward decision
        // notifyCredit is `nonReentrant` and `onlyLBP`. The return-value pattern
        // collapses what was previously a callback (hashrate→lbp.queueReferralReward)
        // into a direct call from LBP — only LBP fires `refVault.triggerReward`,
        // and ONLY on the LP-backed addLp path (this function). transferHashrate /
        // bind back-credit can never produce a non-zero refToReward.
        (address refToReward, uint256 hashrateUsed) =
            hashrate.notifyCredit(lastTransfer_, userLpDelta, useRUsdt, stageTs);

        // One-shot referral reward (LP-backed only). Inlined here from the deleted
        // `queueReferralReward` external. Computes USDT→LBP at max(spot, TWAP_30min)
        // and queues into RefVault. Wrapped in try/catch — RefVault is a
        // side-effect queue; a vault revert here would brick every addLp settle.
        if (refToReward != address(0)) {
            uint256 rewardUsdt = hashrateUsed * 5 / 100;
            if (rewardUsdt > 200 * 1e18) rewardUsdt = 200 * 1e18;
            // Reuse caller-supplied `spotPrice` and `currentCum` (computed once at
            // Layer 6 / POL boundary). Avoids re-reading `pair.getReserves()` in
            // `_spotPrice` and `_calculateTwap` — saves ~5K gas per ref-reward firing.
            uint256 twap30min = _calculateTwapWithCum(snapshot30min_old, currentCum);
            uint256 effectivePrice = spotPrice > twap30min ? spotPrice : twap30min;
            uint256 rewardTokens =
                effectivePrice == 0 ? 0 : rewardUsdt * 1e18 / effectivePrice;
            try refVault.triggerReward(refToReward, rewardTokens, lastTransfer_) {} catch {}
        }

        // FomoVault.notifyLpAdd fires AT STAGE (Layer 8c `_stagePending`), not here.
        // Stage-time firing keeps the FOMO timer in lock-step with the user's
        // addLp commit moment — settle runs in a later tx and may be after the
        // timer would have expired, breaking FOMO's commit-then-wait semantics.
        // See `_stagePending`'s tail block for the gate logic.

        // Stage clear (replaces deleted Layer 8b K-change clear). Always runs after
        // a successful settle; subsequent ops see a clean staging slot.
        _clearStage();
    }

    /// @dev Reset the Layer 8c staging slot. Called from every `_settlePendingLpAdd`
    ///      exit (success and degenerate-early-return) and from `_snapshotAfterPolOperation`.
    ///      Centralizing the three-storage-slot clear ensures no path leaves a stale
    ///      `pendingExpectedUserLp` that could trip `LpMintShortfall` on the next
    ///      `from == pair` op.
    function _clearStage() internal {
        lastTransfer = address(0);
        pendingMintFee = 0;
        pendingExpectedUserLp = 0;
    }

    /// @dev Reconcile burn against `user`'s ledger commitment. Three gates protect
    ///      the "burnLiquidity == ledger debit" invariant:
    ///
    ///      Gate 1 — `ledger > 0`: reject ledgerless target (redirect attack).
    ///      Gate 2 — `ledger > real` (strict, no buffer): proves user actually
    ///        transferred LP from their own balance to pair. Predicted vs. actual
    ///        mintFee use identical inputs, so Method-B's invariant
    ///        `registeredLp[user] == pair.balanceOf(user)` holds exactly without
    ///        an active burn — `real >= ledger` cannot happen legitimately.
    ///      Gate 3 — `burnLiquidity > ledger + LP_TOLERANCE`: reject burns whose
    ///        magnitude exceeds user's commitment.
    ///
    ///      v8: ledger reads through cross-call view `hashrate.registeredLp(user)`.
    ///      Authoritative debit happens in `hashrate.notifyDebit` which re-checks
    ///      `registeredLp >= lpRemoved` and reverts `InsufficientRegisteredLp` if
    ///      the user transferred hashrate away (and thus ledger) since stage time.
    ///
    ///      Debit selection — full vs partial:
    ///        - If `burnLiquidity >= ledger` OR residual `ledger - burnLiquidity ≤
    ///          LP_TOLERANCE`: full-clear ledger.
    ///        - Otherwise: precise debit = burnLiquidity.
    function _reconcileLp(address user, uint256 burnLiquidity) internal {
        // System-address recipient rejected by gate 1 below: vaults / pair /
        // hashrate / this never have `registeredLp > 0` (no Router-mediated
        // addLp from a system address). Explicit `_isSystemAddress` check
        // dropped — gate 1 covers it (~150 gas / ~50 B saved).
        // Front-ends MUST call `Router.removeLiquidity(..., to=msg.sender)`.
        uint256 ledger = hashrate.registeredLp(user);
        if (ledger == 0) revert InvalidBurn();

        uint256 real = IERC20(pair).balanceOf(user);
        if (real >= ledger) revert InvalidBurn();

        if (burnLiquidity > ledger + LP_TOLERANCE) revert InvalidBurn();

        uint256 debitAmt;
        if (burnLiquidity >= ledger || ledger - burnLiquidity <= LP_TOLERANCE) {
            debitAmt = ledger;
        } else {
            debitAmt = burnLiquidity;
        }
        // Direct call (no try/catch) — InsufficientRegisteredLp MUST propagate to
        // unwind the entire user tx. v8 phantom-mining defense relies on this.
        hashrate.notifyDebit(user, debitAmt);
    }

    /// @dev Splits an LBP → pair transfer into "sell" vs "LP-leg". `usdtBalance` is
    ///      pre-computed in Layer 8c to avoid a second `USDT.balanceOf(pair)` read.
    function _splitSellAndLp(uint256 value, uint112 rLBP, uint112 rUSDT, uint256 usdtBalance)
        internal
        view
        returns (uint256 sellPart)
    {
        uint256 usdtDelta = usdtBalance > rUSDT ? usdtBalance - rUSDT : 0;

        uint256 lpPart;
        if (usdtDelta > 0 && rUSDT > 0) {
            uint256 lbpBalance = super.balanceOf(pair);
            uint256 lbpDelta = lbpBalance > rLBP ? lbpBalance - rLBP : 0;
            if (usdtDelta * uint256(rLBP) > lbpDelta * uint256(rUSDT)) {
                uint256 expectedLbp = usdtDelta * uint256(rLBP) / uint256(rUSDT);
                if (expectedLbp > lbpDelta) {
                    lpPart = expectedLbp - lbpDelta;
                    if (lpPart > value) lpPart = value;
                }
            }
        }

        sellPart = value - lpPart;
    }

    // ============================================================
    // Tax
    // ============================================================

    /// @dev Layer 9 + 10 combined into one helper to keep `_update`'s stack frame
    ///      under via-ir's budget. Returns FOMO inputs Layer 12 still needs.
    function _classifyAndRoute(
        address from,
        address to,
        uint256 value,
        uint112 rLBP,
        uint112 rUSDT,
        uint256 spotPriceNow,
        uint256 usdtBalance,
        bool isBurnNow
    ) internal returns (bool isBuy, bool isSell, uint256 sellPart) {
        address recipient = to;
        uint256 tax;
        uint256 sellTaxRate;

        if (to == pair) {
            // v7.0 Router guard: only PancakeRouter callers enter the lpPart
            // classification path (tax-exempt). Every other caller is forced sell.
            if (msg.sender == PANCAKE_ROUTER) {
                sellPart = _splitSellAndLp(value, rLBP, rUSDT, usdtBalance);
            } else {
                sellPart = value;
            }

            if (sellPart > 0) {
                sellTaxRate = _currentSellTaxBps(spotPriceNow);
                // Anti first-dumper advantage: re-evaluate at projected post-sell spot.
                {
                    uint256 denom = uint256(rLBP) + sellPart;
                    uint256 postSpot =
                        spotPriceNow * uint256(rLBP) / denom * uint256(rLBP) / denom;
                    uint256 postTax = _currentSellTaxBps(postSpot);
                    if (postTax > sellTaxRate) sellTaxRate = postTax;
                }
                tax = sellPart * sellTaxRate / 10_000;
                isSell = true;
            }
        } else if (from == pair) {
            if (isBurnNow) {
                recipient = DEAD;
            } else {
                tax = value * BUY_TAX_BPS / 10_000;
                isBuy = true;
            }
        }

        if (tax > 0) {
            if (isBuy) {
                _applyBuyTax(from, tax);
            } else if (isSell) {
                _applySellTax(from, tax, sellTaxRate);
            }
            super._update(from, recipient, value - tax);
        } else {
            super._update(from, recipient, value);
        }
    }

    function _applyBuyTax(address from, uint256 tax) internal {
        uint256 polPart = tax * BUY_POL_BPS / 10_000;
        uint256 fomoPart = tax - polPart;
        if (polPart > 0) super._update(from, address(polVault), polPart);
        if (fomoPart > 0) super._update(from, address(fomoVault), fomoPart);
    }

    /// @dev Sell-tax application. Splits the levied `tax` into:
    ///        basePart = tax × 500 / taxBps        (always fixed 5% slice at base rate)
    ///        dynPart  = tax − basePart            (0-15% dynamic slice)
    ///      Base distribution (20/40/40): dev / BurnVault / RefVault.
    ///      Dynamic distribution (40/40/20): FomoVault / PolVault / DEAD burn.
    ///
    ///      Reentrancy safety: vault payouts re-enter LBP._update with `from = vault`,
    ///      which Layer 2 catches and short-circuits to plain super._update.
    function _applySellTax(address seller, uint256 tax, uint256 taxBps) internal {
        uint256 basePart = tax * SELL_TAX_BASE_BPS / taxBps;
        uint256 dynPart = tax - basePart;

        // Base: 20/40/40 dev/burn/ref. Residue to ref.
        uint256 baseDev = basePart * SELL_BASE_DEV_PCT / 100;
        uint256 baseBurn = basePart * SELL_BASE_BURN_PCT / 100;
        uint256 baseRef = basePart - baseDev - baseBurn;

        if (baseDev > 0) {
            super._update(seller, devWallet, baseDev);
        }
        if (baseBurn > 0) {
            super._update(seller, address(burnVault), baseBurn);
            try burnVault.processQueue() {} catch {}
        }
        if (baseRef > 0) {
            super._update(seller, address(refVault), baseRef);
            try refVault.processQueue() {} catch {}
        }

        // Dynamic: 40/40/20 fomo/pol/dead.
        uint256 dynFomo = dynPart * SELL_DYN_FOMO_PCT / 100;
        uint256 dynPol = dynPart * SELL_DYN_POL_PCT / 100;
        uint256 dynBurn = dynPart - dynFomo - dynPol;

        if (dynFomo > 0) {
            super._update(seller, address(fomoVault), dynFomo);
        }
        if (dynPol > 0) {
            super._update(seller, address(polVault), dynPol);
        }
        if (dynBurn > 0) {
            super._update(seller, DEAD, dynBurn);
        }

        emit SellTax(seller, tax, taxBps);
    }

    /// @dev Sell-tax rate:
    ///        base = max(peak30min × 0.9, peak30d)
    ///        taxBps = 500 + min(1500, deviationBps × 30 / 100)
    function _currentSellTaxBps(uint256 spot) internal view returns (uint256) {
        uint256 peak30min = _getPeak30MinOverWindow() * 90 / 100;
        uint256 peak30d = uint256(peakTwap30d);
        uint256 base = peak30d > peak30min ? peak30d : peak30min;
        if (base == 0 || spot >= base) return SELL_TAX_BASE_BPS;
        uint256 addBps = (base - spot) * 10_000 / base * SELL_TAX_SLOPE_NUM / SELL_TAX_SLOPE_DEN;
        if (addBps > SELL_TAX_DYN_CAP_BPS) addBps = SELL_TAX_DYN_CAP_BPS;
        return SELL_TAX_BASE_BPS + addBps;
    }

    // ============================================================
    // POL — callbacks from PolVault
    // ============================================================

    function onPolStart() external {
        if (msg.sender != address(polVault)) revert OnlyPolVault();
        _resolvePendingBeforePolOperation();
    }

    function onPolEnd() external {
        if (msg.sender != address(polVault)) revert OnlyPolVault();
        _snapshotAfterPolOperation();
    }

    function _resolvePendingBeforePolOperation() internal {
        uint256 totalLpNow = IPancakePair(pair).totalSupply();
        uint256 kLastNow = IPancakePair(pair).kLast();
        bool kLastChanged_ = kLastNow != lastKLast;
        (uint112 rLBP, uint112 rUSDT, uint32 ts) = _getReserves();
        uint256 spotPrice = rLBP > 0 ? uint256(rUSDT) * 1e18 / uint256(rLBP) : 0;
        uint256 currentCum = _currentPriceCumulative(rLBP, rUSDT, ts);

        // Defence-in-depth: settle (with verify) any pending stage before flushPol
        // changes pair state. Pass `pair` as `from` so the verify gate engages
        // identically to Layer 7a (which requires `from == pair`).
        // M-2: realizeFee = true (always) to match Layer 7a's user-trade path.
        // (v8 Plan A: explicit `_updateMining` here is no longer needed —
        // `_verifyAndSettle` may call `notifyCredit` which `_mint`s into hashrate's
        // `_update` and self-ticks emission. Subsequent user ops self-tick again
        // through any `notifyHarvest` / `claim`.)
        _verifyAndSettle(
            totalLpNow,
            /*burnLiquidity=*/ 0,
            /*realizeFee=*/ true,
            /*from=*/ pair,
            /*kLastChanged=*/ kLastChanged_,
            rUSDT,
            spotPrice,
            currentCum
        );
    }

    /// @dev Shared verify-and-settle for Layer 7a and POL callback.
    ///
    ///      Verify catches C2 piggyback (attacker burn neutralizes user mint via
    ///      precise offset + USDT donation, defeating both `_detectBurn` signals).
    ///
    ///      Verify gate logic:
    ///        - `from == pair`: only check during pair-originating LBP transfers (buy/burn).
    ///        - `kLastChanged || !cachedFeeOn`: kLast moved (mint/burn end-write) OR
    ///          feeTo is off (kLast frozen, fall back to always-check).
    ///
    ///      Settle uses `adjustedTotalLp = totalLpNow + burnLiquidity` to neutralize a
    ///      concurrent burn detected in the calling `_update`.
    function _verifyAndSettle(
        uint256 totalLpNow,
        uint256 burnLiquidity,
        bool realizeFee,
        address from,
        bool kLastChanged,
        uint112 rUsdt,
        uint256 spotPrice,
        uint256 currentCum
    ) internal {
        uint256 lastLp = lastTotalLp;
        uint256 actualLpDelta = totalLpNow > lastLp ? totalLpNow - lastLp : 0;
        if (
            pendingExpectedUserLp > 0
            && from == pair
            && (kLastChanged || !cachedFeeOn)
        ) {
            uint256 expected = uint256(pendingExpectedUserLp) + uint256(pendingMintFee);
            if (expected > actualLpDelta + burnLiquidity + LP_TOLERANCE) {
                revert LpMintShortfall();
            }
        }
        uint256 adjustedTotalLp = totalLpNow + burnLiquidity;
        if (adjustedTotalLp > lastLp) {
            // Only USDT-side reserve is needed: LBPHashrate's notifyCredit computes
            // `2 × lpDelta × stageReserveUsdt / stageTotalLp` (the LBP side is
            // implicit in the × 2 factor — equals USDT side at stage-time spot price).
            // `spotPrice` + `currentCum` flow through to the inline ref-reward block,
            // avoiding a redundant `_spotPrice` + `_calculateTwap` re-read of pair state.
            _settlePendingLpAdd(adjustedTotalLp, lastLp, realizeFee, rUsdt, spotPrice, currentCum);
        }
    }

    /// @dev POL flush boundary — pair reserves advance via Router addLiquidity inside
    ///      the flush, so all addLp staging is stale on return. The full staging set
    ///      is cleared.
    function _snapshotAfterPolOperation() internal {
        lastTotalLp = IPancakePair(pair).totalSupply();
        lastKLast = IPancakePair(pair).kLast();
        _clearStage();
    }

    // ============================================================
    // Active burn
    // ============================================================

    /// @dev Active-burn 1.3× reward is an intentional deflationary incentive. Per cycle
    ///      the user destroys LBP to DEAD and receives 1.3× back from BurnVault — net
    ///      0.3× extracted per cycle, paid from sell-tax accumulated in the vault.
    ///      Single source of truth for both the per-call hard cap (10 LBP — revert)
    ///      and the per-call min entry (1 USDT-eq — silent skip).
    function _onActiveBurn(address user, uint256 burnedAmount, uint256 spotPrice) internal {
        // Hard cap: any single active-burn > 10 LBP reverts. Users wanting to
        // destroy more must split into multiple txs (also bounds vault drain rate).
        if (burnedAmount > ACTIVE_BURN_MAX_LBP) revert ActiveBurnTooLarge();

        // Minimum entry: burn must be worth at least 1 USDT at spot. Switched from
        // TWAP_30min to spot for user-intuitive accounting. burnedAmount × spotPrice
        // is in scale "USDT-wei × 1e18", so 1 USDT = 1e18 × 1e18 = 1e36.
        if (spotPrice == 0) return;
        if (burnedAmount * spotPrice < ACTIVE_BURN_MIN_USDT * 1e18) return;

        burnVault.triggerReward(user, burnedAmount * 13 / 10);
    }

    // ============================================================
    // Mining — DELETED (v8 Plan A)
    // ============================================================
    //
    // Emission curve, accumulator-tick, and `dailyEmission()` view all live in
    // LBPHashrate now. LBP retains only the cap clamp inside `mintReward`.
    // External callers wanting the daily emission projection should query
    // `hashrate.dailyEmission()` instead.

    // ============================================================
    // TWAP
    // ============================================================

    /// @dev Reserves + ts threaded in by callers (Layer 6 captures them once for the
    ///      whole `_update`). token0 is USDT → pass `rUSDT` (= r0) and `rLBP` (= r1).
    function _currentPriceCumulative(uint112 rLBP, uint112 rUSDT, uint32 ts)
        internal
        view
        returns (uint256)
    {
        uint256 cum = IPancakePair(pair).price1CumulativeLast();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - ts;
            if (elapsed > 0 && rUSDT > 0 && rLBP > 0) {
                uint256 spotQ112 = (uint256(rUSDT) << 112) / rLBP;
                cum += spotQ112 * elapsed;
            }
        }
        return cum;
    }

    function _calculateTwap(TwapSnapshot memory snap) internal view returns (uint256) {
        (uint112 rLBP, uint112 rUSDT, uint32 ts) = _getReserves();
        return _calculateTwapWithCum(snap, _currentPriceCumulative(rLBP, rUSDT, ts));
    }

    /// @dev Two early-return paths, both fall back to spot:
    ///      1. `snap.timestamp == 0` (cascade not yet seeded post-deploy).
    ///      2. `elapsed == 0` (read in same block as rotation).
    function _calculateTwapWithCum(TwapSnapshot memory snap, uint256 currentCum)
        internal
        view
        returns (uint256)
    {
        if (snap.timestamp == 0) return _spotPrice();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - snap.timestamp;
            if (elapsed == 0) return _spotPrice();
            uint256 avgQ112 = (currentCum - uint256(snap.priceCumulative)) / elapsed;
            return (avgQ112 * 1e18) >> 112;
        }
    }

    /// @param currentCum Pre-computed at Layer 6 — shared with Layer 8e and Layer 13.
    function _maybeUpdateTwapSnapshots(uint256 currentCum) internal {
        uint32 nowTime = uint32(block.timestamp);
        unchecked {
            bool need30m = nowTime - snapshot30min_new.timestamp >= 10 minutes;
            bool need30d = nowTime - snapshot30d_new.timestamp >= 10 days;
            if (!need30m && !need30d) return;

            TwapSnapshot memory fresh = TwapSnapshot({priceCumulative: uint224(currentCum), timestamp: nowTime});

            if (need30m) {
                snapshot30min_old = snapshot30min_mid;
                snapshot30min_mid = snapshot30min_new;
                snapshot30min_new = fresh;
            }
            if (need30d) {
                snapshot30d_old = snapshot30d_mid;
                snapshot30d_mid = snapshot30d_new;
                snapshot30d_new = fresh;
            }
        }
    }

    // ============================================================
    // Peak TWAP tracking for sell-tax base price
    // ============================================================

    /// @dev Called at Layer 8e of `_update`, BEFORE Layer 9 reads peaks. Maintains:
    ///        - `peakTwap30d` (all-time max of TWAP_30d, permanent memory)
    ///        - `peak30minDaily[30]` (rolling 30-day per-day max of TWAP_30min)
    ///      O(1) via TTL-cached max; rescan happens at most once per 30 days.
    function _updatePeakTwap(uint256 currentCum) internal {
        // peakTwap30d update gates (BOTH must hold):
        //   (a) calendar: `block.timestamp >= openTime + 30 days`
        //   (b) cascade-fill: `snap_30d_old.timestamp != 0`
        if (snapshot30d_old.timestamp != 0 && block.timestamp >= uint256(openTime) + 30 days) {
            uint256 twap30d = _calculateTwapWithCum(snapshot30d_old, currentCum);
            if (twap30d > uint256(peakTwap30d)) {
                peakTwap30d = uint224(twap30d);
            }
        }

        uint32 today = uint32(block.timestamp / 1 days);
        uint32 lastDay = peak30minLastDay;
        uint32 currentIdx;

        if (today > lastDay) {
            uint32 daysPassed = today - lastDay;
            uint32 oldIdx = peak30minDayIdx;
            uint32 clearCount = daysPassed >= 30 ? 30 : daysPassed;

            unchecked {
                for (uint32 d = 1; d <= clearCount; d++) {
                    peak30minDaily[(oldIdx + d) % 30] = 0;
                }
                currentIdx = (oldIdx + daysPassed) % 30;
                peak30minDayIdx = currentIdx;
            }
            peak30minLastDay = today;
        } else {
            currentIdx = peak30minDayIdx;
        }

        // Rescan if the cached max's source day has expired.
        if (today >= cachedPeakDay + 30) {
            uint224 newMax;
            uint32 newDay = today;
            unchecked {
                for (uint32 i = 0; i < 30; i++) {
                    uint224 v = peak30minDaily[i];
                    if (v > newMax) {
                        newMax = v;
                        newDay = today - ((currentIdx + 30 - i) % 30);
                    }
                }
            }
            cachedPeakMax = uint192(newMax);
            cachedPeakDay = newDay;
        }

        // Record today's running max + maintain cache forward.
        uint256 twap30min = _calculateTwapWithCum(snapshot30min_old, currentCum);
        if (twap30min > uint256(peak30minDaily[currentIdx])) {
            peak30minDaily[currentIdx] = uint224(twap30min);
            if (twap30min > uint256(cachedPeakMax)) {
                cachedPeakMax = uint192(twap30min);
                cachedPeakDay = today;
            }
        }
    }

    /// @dev O(1) lookup via TTL cache.
    function _getPeak30MinOverWindow() internal view returns (uint256) {
        return uint256(cachedPeakMax);
    }

    // ============================================================
    // Public views
    // ============================================================

    /// @notice ERC20 balance — virtual-credit override.
    ///         For non-system addresses, returns `raw + pending` where `pending`
    ///         is the user's unclaimed mining rewards (static + node) computed
    ///         live by `LBPHashrate.pendingRewards(account)`. Wallets / DEX UIs
    ///         see "spendable balance = perceived balance" without needing to
    ///         simulate `claim()` off-chain.
    ///
    ///         System addresses (`this`, vaults, pair, hashrate, DEAD) return raw
    ///         (they don't accumulate hashrate-derived pending; the cross-call
    ///         would always return 0, so we skip it for gas).
    ///
    ///         Internal LBP code that needs the true `_balances[u]` value uses
    ///         `super.balanceOf(...)` directly (e.g., LP-leg LBP delta read in
    ///         `_splitSellAndLp`); ERC20 transfer mechanics in OZ check
    ///         `_balances[from]` directly without going through `balanceOf`, so
    ///         the override does not affect transfer correctness.
    /// @dev    Cross-call adds ~5K gas per external `balanceOf` call. Acceptable
    ///         for a view function (no on-chain caller relies on it in a hot path).
    function balanceOf(address account) public view override returns (uint256) {
        uint256 raw = super.balanceOf(account);
        if (
            account == address(this) || account == pair || account == DEAD
                || account == address(burnVault) || account == address(refVault)
                || account == address(polVault) || account == address(fomoVault)
                || account == address(hashrate)
        ) {
            return raw;
        }
        return raw + hashrate.pendingRewards(account);
    }

    /// @notice Underlying `_balances[u]` without virtual credit. Protocol-internal
    ///         callers that explicitly want raw (FomoVault.pool, vault reserves,
    ///         tests measuring realized mint deltas) use this.
    function rawBalanceOf(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice Current sell-tax rate (bps).
    /// @dev STALENESS NOTE (accepted limitation, bytecode-bounded):
    ///      Reads `cachedPeakMax` directly. The cache is refreshed by `_updatePeakTwap`
    ///      (Layer 8e) before each on-chain trade computes its tax. View-side rescan
    ///      simulation pushes bytecode over EIP-170; staleness only manifests after
    ///      ≥30 days of zero trades and always errs in user's favor (real tax ≤
    ///      displayed tax).
    function currentSellTax() external view returns (uint256) {
        return _currentSellTaxBps(_spotPrice());
    }
}
