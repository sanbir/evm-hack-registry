// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPancakePair} from "./interfaces/IPancakePair.sol";
import {IPancakeFactory} from "./interfaces/IPancakeFactory.sol";
import {SqrtMath} from "./libs/SqrtMath.sol";
import {BurnVault} from "./BurnVault.sol";
import {RefVault} from "./RefVault.sol";
import {PolVault} from "./PolVault.sol";
import {IFomoVault} from "./interfaces/IFomoVault.sol";
import {HashrateRegistry} from "./HashrateRegistry.sol";
import {IWhaleZapRouter} from "./interfaces/IWhaleZapRouter.sol";
import {WHALEHashrate} from "./WHALEHashrate.sol";

/**
 * @title WHALE — WHALE (v8.0)
 * @notice Immutable ERC-20 token. v8 architecture externalizes hashrate / mining /
 *         referral state into a sibling contract `WHALEHashrate (hWHALE)`. WHALE keeps:
 *
 *           - ERC-20 token state (pure: no virtual-credit balanceOf override)
 *           - Sell / buy / dynamic tax routing
 *           - Method-B add/remove-LP detection (stage / verify / settle pipeline)
 *           - TWAP cascade + 30-day peak tracker (sell-tax base price)
 *           - FOMO trigger (Layer 12) — forwards to FomoVault.notifyTrade
 *           - Active burn hook (Layer 11) — forwards to BurnVault.triggerReward
 *           - POL trigger via 0.001 WHALE magic transfer to FomoVault
 *           - Mining emission decay + cap enforcement at the `awardMiningEmission` boundary
 *
 *         Externalized to WHALEHashrate (callable via `hashrate.notify*` cross-call):
 *
 *           - userHashrate / totalHashrate / sharedHashrate / validDownlines
 *           - Mining accumulator (staticAccPerShare / nodeAccPerShare) + harvest
 *           - 15-generation dynamic distribution
 *           - Referral tree (`referrer`, bind / `_executeBind` / one-shot reward)
 *           - Node qualification + count
 *           - LP commitment ledger (`registeredLp`, atomic with hashrate balance)
 *
 *         Cross-contract trust model: WHALEHashrate's `notify*` endpoints are
 *         `onlyWHALE`; WHALE's `awardMiningEmission` is `onlyHashrate`.
 *         The recursion `WHALE._update → hashrate.notifyHarvest → hashrate._harvest →
 *         whale.awardMiningEmission → WHALE._mint → super._update(0, to, amt)` terminates at
 *         Layer 1 (`from == address(0)` short-circuit) — no pipeline re-entry.
 *
 * === Manipulation defence ===
 *
 *   (a) Method-B LP tracking (v8.x): `_stagePending` (Layer 8c) writes
 *       `lastTransfer / pendingMintFee / pendingExpectedUserLp` for ANY
 *       `to == pair` WHALE transfer that has a non-zero predicted user LP
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
 *       on `msg.sender == PANCAKE_ROUTER && tx.origin == from` (v9 dropped
 *       the redundant `from.code.length == 0` belt-and-braces gate so
 *       EIP-7702 delegated EOAs participate normally).
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
 * 2. Manual-atomic addLp (single-tx `usdt.transfer + whale.transfer + pair.mint(self)`)
 *    is supported for hashrate / LP credit but does NOT confer FOMO entry — only
 *    Router-mediated addLp does. Manual-split-tx (LP-leg and pair.mint in different
 *    transactions) remains exposed to dust frontrun (documented in CLAUDE.md
 *    "addLp 原子性" known limit).
 *
 * === Centralization / "owner-like" surface (for CertiK / Slither / GoPlus) ===
 *
 *   This contract has NO owner. No `Ownable`, no admin mapping, no upgrade
 *   path. No openable/closable flag. Trading is live from constructor. Every
 *   storage field that could resemble a privileged address is `immutable`
 *   (set at construction, unchangeable). The patterns below may be
 *   auto-flagged by centralization detectors; each is bounded and intentional:
 *
 *   - `awardMiningEmission(to, amount) onlyHashrate` — restricted to the WHALEHashrate
 *     contract address (`immutable`). No EOA can call. Cumulative mints
 *     across all calls are bounded by `MINING_MAX` (immutable cap).
 *
 *   - `protocolTreasury` — `immutable` fee recipient for 20% of base sell tax.
 *     Cannot be changed. Receives a fixed protocol-revenue share by design.
 *
 *   - `refreshFeeToCache()` — permissionless; only updates a single bool
 *     cache from `factory.feeTo()`. No privilege.
 *
 *   - Layer 14 `referrer[from] = to` magic-bind — caller binds THEMSELVES
 *     under target; cannot force-bind a third party (`msg.sender == from`).
 *
 *   - Layer 15 POL flush trigger — permissionless; `tx.origin == msg.sender`
 *     gates contracts (incl. constructor-time bypass). Caller earns 0.5%
 *     reward as an open keeper incentive.
 *
 *   Slither annotations (`// slither-disable-next-line centralization-risk`)
 *   are inlined at the relevant sites with WHY comments.
 *
 *   See `audits/CENTRALIZATION-ANALYSIS.md` for the audit-ready summary
 *   covering all six contracts in the protocol.
 */
contract WHALE is ERC20, ERC20Permit, ReentrancyGuardTransient {
    // ============================================================
    // Constants
    // ============================================================

    uint256 public constant TOTAL_SUPPLY = 21_000_000 * 1e18;
    uint256 private constant INITIAL_SUPPLY = 21_000 * 1e18;
    /// @dev MINING_MAX = TOTAL_SUPPLY - INITIAL_SUPPLY. `private` to avoid a derived-value
    ///      getter; consumers can compute from the two above. Mirrored in WHALEHashrate
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

    /// @dev Referral reward = 5% of the downline's `hashrateUsed` (= 2 × LP-side USDT
    ///      contribution = total LP value in USDT). Capped at REF_REWARD_CAP_USDT to
    ///      bound the per-event payout. Cap is denominated in USDT and converted to
    ///      WHALE at the effective spot/TWAP price at credit time.
    uint256 private constant REF_REWARD_BPS = 500;        // 5%
    uint256 private constant REF_REWARD_CAP_USDT = 200 * 1e18;

    /// @dev Active-burn min-entry threshold: 1 USDT-equivalent at SPOT. Cap eligible
    ///      burn at 10 WHALE per call so reward cannot exceed 13 WHALE per single burn.
    uint256 private constant ACTIVE_BURN_MIN_USDT = 1e18;       // 1 USDT
    uint256 private constant ACTIVE_BURN_MAX_WHALE = 10 * 1e18;   // 10 WHALE eligible per call

    /// @dev Shared 0.001 WHALE magic-value used by two distinct user UX flows:
    ///        (a) Layer 15 POL flush trigger when `to == fomoVault`
    ///            (`POL_TRIGGER_AMOUNT` alias).
    ///        (b) Layer 14 referral magic-bind when `to != fomoVault` and
    ///            equals an upline EOA (`REFCODE_AMOUNT` alias).
    ///      Disambiguated entirely by `to`. Same numeric value lets wallets
    ///      surface "send 0.001 WHALE" as a uniform "magic protocol action".
    uint256 public constant MAGIC_TRANSFER_AMOUNT = 1 * 10 ** 15;

    /// @dev Alias for POL flush trigger (see `MAGIC_TRANSFER_AMOUNT`). Caller
    ///      receives 0.5% of the POL buffer (capped at 10 WHALE) as flush
    ///      incentive; the 0.001 WHALE donation joins the FOMO pool.
    uint256 public constant POL_TRIGGER_AMOUNT = MAGIC_TRANSFER_AMOUNT;

    /// @dev Alias for referral magic-bind (see `MAGIC_TRANSFER_AMOUNT`). Mirrors
    ///      `WHALEHashrate.REFCODE_AMOUNT`.
    uint256 public constant REFCODE_AMOUNT = MAGIC_TRANSFER_AMOUNT;

    // Tolerance for Layer 7a verify (mint-fee predictor drift). 100 wei absorbs
    // any 1-2 wei drift without enabling economically meaningful evasion.
    uint256 private constant LP_TOLERANCE = 100;

    // (Emission split moved to WHALEHashrate in v8: 50% static / 10% node / 40% dynamic.
    // The 40% dynamic emerges as 80% of each user's static reward inside
    // `_distributeDynamic`. Cap enforcement still funnels through `awardMiningEmission` here.)

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
    error InvalidWHALEAddress();
    error InvalidRegistry();
    error ZeroAddress();
    error OnlyPolVault();
    /// @dev `awardMiningEmission` callable only by the wired WHALEHashrate contract.
    error OnlyHashrate();
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
    ///      `ACTIVE_BURN_MAX_WHALE` (10 WHALE). Users wanting to destroy more must split
    ///      into multiple txs.
    error ActiveBurnTooLarge();
    /// @dev Direct transfers to the WHALE contract itself are forbidden. With FOMO
    ///      extracted to `fomoVault`, WHALE no longer uses self-balance as the pool —
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
    // moved to WHALEHashrate — emitted from `notifyCredit` / `_harvest` / etc.
    // ReferrerBound and ReferralRewardTriggered remain on RefVault.

    // ============================================================
    // Immutables
    // ============================================================

    /// @notice Fixed protocol-treasury fee recipient. Immutable; cannot be reassigned.
    ///         Receives 20% of the base sell-tax slice as protocol revenue.
    address public immutable protocolTreasury;
    IERC20 public immutable USDT;
    IPancakeFactory public immutable PANCAKE_FACTORY;
    address public immutable pair;
    BurnVault public immutable burnVault;
    RefVault public immutable refVault;
    PolVault public immutable polVault;
    IFomoVault public immutable fomoVault;
    /// @notice v8 sibling: holds hashrate balance, mining accumulator, referral tree,
    ///         node state, and the LP commitment ledger. Cross-contract calls flow
    ///         L↔H via the `notify*` (WHALE→hashrate) and `awardMiningEmission`
    ///         (hashrate→WHALE) endpoints. The one-shot referral reward decision
    ///         is returned synchronously from `notifyCredit` for WHALE to fire
    ///         `refVault.triggerReward` directly — no separate hashrate→WHALE path.
    WHALEHashrate public immutable hashrate;
    /// @dev Canonical PancakeSwap V2 Router on BSC mainnet. v8 retains the v7.0
    ///      Router-only stage-write gate for Method-B's Layer 8c.
    address public immutable PANCAKE_ROUTER;

    /// @dev v9.x one-click zap helper. Two protocol concessions to this address:
    ///        1. Buy-tax exempt — Layer 2 short-circuits `from == pair && to == zap`.
    ///        2. Method-B credit pass-through — when Layer 7a settle finds
    ///           `lastTransfer == WHALE_ZAP_ROUTER`, it cross-calls
    ///           `IWhaleZapRouter.pendingUser()` and credits that address instead.
    ///      Both concessions are narrow and only active when the zap is the
    ///      counterparty; regular users / routers see no behavior change.
    address public immutable WHALE_ZAP_ROUTER;

    // ============================================================
    // Storage
    // ============================================================

    // Slot-packed: openTime (8B) + cachedFeeOn (1B) + 23B free.
    // (`lastEmissionUpdate` lives in WHALEHashrate alongside the emission curve.
    //  Trading is live from constructor — `openTime = block.timestamp` set then.)
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
    //   2. The ONLY other `_mint` path is `awardMiningEmission` (gated `onlyHashrate`),
    //      which represents pure mining emission.
    //   3. There is NO `_burn` in v8 WHALE — active burns route to DEAD via
    //      `super._update`, leaving totalSupply intact.
    // See `totalEmitted()` view below + `awardMiningEmission` for cap enforcement.
    // (Plan A: `lastEmissionUpdate` + `_calculateEmission` + accumulator
    // advance migrated to WHALEHashrate. WHALE retains only the cap clamp here.)

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
    // sharedHashrate / validDownlines. All migrated to WHALEHashrate. (v9 also
    // removes the v8 `rewardTriggered` one-shot latch — referral reward
    // now fires on every qualifying addLp.)

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
    ///                  (predicted via off-chain CREATE2 computation). WHALE reads them
    ///                  here as immutable storage. The cycle "WHALE needs hashrate_addr,
    ///                  hashrate needs WHALE_addr, vaults need WHALE_addr" is broken
    ///                  because `_registry` is deployed via REGULAR CREATE (nonce-based
    ///                  address, independent of args) BEFORE WHALE. WHALEHashrate and
    ///                  vaults are deployed AFTER WHALE at the predicted CREATE2
    ///                  addresses. See `src/HashrateRegistry.sol` for the full chain.
    constructor(
        address _protocolTreasury,
        address _receiver,
        IERC20 _usdt,
        IPancakeFactory _factory,
        HashrateRegistry _registry,
        address _router
    )
        ERC20("WHALE", "WHALE")
        ERC20Permit("WHALE")
    {
        // L-1 router sanity (constructor-arg-only — fire early, before the
        // WHALE-address invariant, so test harnesses with arbitrary salts surface the
        // intended error rather than the address-invariant tripwire).
        if (_router == address(0) || _router.code.length == 0) revert ZeroAddress();

        // Reject zero / self / pair as protocolTreasury.
        //   - address(0): sell-tax slice would route to address(0), which OZ
        //     ERC20's _update treats as a real burn → totalSupply drops below
        //     INITIAL_SUPPLY → mining-emission cap clamp underflows.
        //   - address(this): tax flowing to WHALE itself enters virtual-credit
        //     paths not designed for a tax recipient.
        //   - pair: tax flowing to pair would silently inflate AMM reserves.
        if (_protocolTreasury == address(0) || _protocolTreasury == address(this)) revert ZeroAddress();

        if (address(this) <= address(_usdt)) revert InvalidWHALEAddress();

        protocolTreasury = _protocolTreasury;
        USDT = _usdt;
        PANCAKE_FACTORY = _factory;
        PANCAKE_ROUTER = _router;

        pair = _factory.createPair(address(this), address(_usdt));

        // Final protocolTreasury check — reject pair as well. Tax routed to pair
        // would silently inflate AMM reserves. Pair address is only known
        // post-createPair.
        if (_protocolTreasury == pair) revert ZeroAddress();

        // Read all 6 wired addresses from the registry. They were predicted off-chain
        // to match the (yet-to-be-deployed) CREATE2 addresses; the deploy script
        // verifies the match post-deploy via sanity asserts.
        //
        // Defense-in-depth: reject zero-address wiring at construction. Without this,
        // a malformed registry could poison WHALE with vault=0 (silent fund loss on
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
        hashrate = WHALEHashrate(_hashrate);
        burnVault = BurnVault(_burnVault);
        refVault = RefVault(_refVault);
        polVault = PolVault(_polVault);
        fomoVault = IFomoVault(_fomoVault);
        // v9.x: zapRouter is optional in the registry. Zero is acceptable —
        // it simply means no buy-tax exemption and no credit pass-through are
        // active for this deployment (gate conditions `to == WHALE_ZAP_ROUTER`
        // and `creditUser == WHALE_ZAP_ROUTER` can never match address(0) in
        // any practical Method-B flow). Useful for test rigs that don't need
        // the zap surface, and for staged migration where the zap is deployed
        // after WHALE on the same chain.
        WHALE_ZAP_ROUTER = _registry.zapRouter();

        _mint(_receiver, INITIAL_SUPPLY);

        // v8.x: receiver self-loop is installed by WHALEHashrate's OWN constructor
        // (replaces former cross-call to `hashrate.bindReceiver(_receiver)`).
        // The receiver is now passed to WHALEHashrate as a constructor arg,
        // anchoring it atomically with hashrate construction.

        // Snapshot factory.feeTo() state. Used by Layer 7a verify gate.
        cachedFeeOn = _factory.feeTo() != address(0);

        // Anchor every time-based clock at constructor block.timestamp. Trading
        // is "live" from the moment of deploy — there is no separate
        // openTrading() call. Until the deployer adds initial liquidity via
        // Router.addLiquidity, the pair has 0 reserves so PancakeSwap's swap
        // formula naturally reverts (div-by-zero). The deployer must add
        // initial liquidity post-deploy via the canonical Router atomic path
        // and avoid transferring WHALE to untrusted addresses in the meantime —
        // standard operational discipline covers the pre-LP risk window.
        //
        // WHALEHashrate and FomoVault both self-initialize their respective
        // emission and FOMO timer anchors in their own constructors — no
        // cross-call from here. All three contracts deploy within seconds of
        // each other in the same broadcast.
        openTime = uint64(block.timestamp);

        // Peak tracker day anchor.
        uint32 today = uint32(block.timestamp / 1 days);
        peak30minLastDay = today;
        cachedPeakDay = today;

        // TWAP cascade snapshots intentionally NOT anchored — pre-mint price is
        // undefined. Layer 13 auto-seeds on the first post-mint `_update`.
    }

    /// @notice Re-read `factory.feeTo()` state into `cachedFeeOn`. Permissionless.
    function refreshFeeToCache() external {
        cachedFeeOn = PANCAKE_FACTORY.feeTo() != address(0);
    }

    /// @notice Permissionless settle trigger for the currently-staged Method-B
    ///         user. Anyone may call to fire Layer 7a settle if a `pair.mint`
    ///         has changed `kLast` or `totalSupply` since the stage was
    ///         written. No-op (returns silently) when no stage is pending or
    ///         signals haven't fired.
    ///
    /// @dev    Use cases:
    ///           1. `WhaleZapRouter.zap()` calls this instead of
    ///              `whale.transfer(user, 0)` to avoid the Layer 14 magic-bind
    ///              side effect AND skip the wasteful Layer 8 harvest of zap.
    ///           2. Manual addLp users (Router.addLiquidity from own wallet)
    ///              can self-finalize without waiting for someone else's
    ///              `from=pair` op to settle them.
    ///           3. Keeper bots can poll `lastTransfer != 0` and trigger
    ///              settle proactively.
    ///
    ///         Compared to `whale.transfer(user, 0)` as settle trigger this
    ///         saves ~35K gas:
    ///           - Skips Layer 8 harvest cycle (both `from` and `to` harvests
    ///             are no-ops in the zap case but spend gas to confirm).
    ///           - Skips Layer 14 magic-bind try/catch (which would otherwise
    ///             set `referrer[caller] = staged_user` on first call).
    ///           - Skips Layer 9 classification / Layer 15 POL trigger checks.
    ///           - Skips the underlying `super._update(from, to, 0)` work.
    ///
    /// @dev    Security: the entry passes `from = address(0)` to
    ///         `_verifyAndSettle`. The verify gate
    ///         (`pendingExpectedUserLp > 0 && from == pair && ...`) requires
    ///         `from == pair`; with `from = 0` it can never fire — so the
    ///         `LpMintShortfall` revert path is unreachable here. This is
    ///         correct because the verify gate's purpose (catch C2 piggyback
    ///         on burn / skim) only makes sense when something is INSIDE the
    ///         pipeline at `from == pair`. A standalone settle just
    ///         materializes whatever the natural pipeline would have done.
    ///
    /// @dev    Stage write defense: `nonReentrant` blocks settle-in-settle.
    ///         Layer 8d snapshot updates (`lastTotalLp`, `lastKLast`) happen
    ///         identically to the in-pipeline path so subsequent calls don't
    ///         double-fire.
    function settle() external nonReentrant {
        // Fast path: nothing staged.
        if (lastTransfer == address(0)) return;

        uint256 totalLpNow = IPancakePair(pair).totalSupply();
        uint256 kLastNow = IPancakePair(pair).kLast();
        bool kLastChanged = kLastNow != lastKLast;
        bool totalLpChanged = totalLpNow != lastTotalLp;

        // Layer 7a outer gate. No-op return if signals haven't fired —
        // matches `_updateImpl`'s gate exactly.
        if (!kLastChanged && !totalLpChanged && cachedFeeOn) return;

        (uint112 rWHALE, uint112 rUSDT, uint32 _ts) = _getReserves();
        uint256 spotPriceNow = rWHALE > 0 ? uint256(rUSDT) * 1e18 / uint256(rWHALE) : 0;
        uint256 currentCum = _currentPriceCumulative(rWHALE, rUSDT, _ts);

        _verifyAndSettle(
            totalLpNow,
            0,               // burnLiquidity — no burn here
            true,            // realizeFee — same as pipeline path
            address(0),      // from — bypasses LpMintShortfall verify (see NatSpec)
            kLastChanged,
            rUSDT,
            spotPriceNow,
            currentCum
        );

        // Layer 8d snapshot sync — same as `_updateImpl` path.
        if (totalLpChanged) lastTotalLp = totalLpNow;
        if (kLastChanged) lastKLast = kLastNow;
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
    // Hashrate-gated callbacks (WHALE-side surface for cross-contract call)
    // ============================================================

    /// @notice Called by WHALEHashrate when a user's pending mining reward materializes.
    ///         Enforces the global emission cap.
    /// @dev    Saturates if cap exceeded — does NOT revert. Lets WHALEHashrate's
    ///         `_harvest` proceed gracefully past the cap (subsequent calls mint 0).
    ///         The accumulator advance lives in WHALEHashrate's `_tickEmission`
    ///         (v8 Plan A); realized mints saturate here independently.
    ///
    ///         CertiK / Slither may flag `onlyHashrate` as a centralization
    ///         vector. It is NOT: the only valid caller is the WHALEHashrate
    ///         contract whose address is set `immutable` at construction and
    ///         cannot be reassigned. Total emissions across all calls are
    ///         bounded by `MINING_MAX = TOTAL_SUPPLY - INITIAL_SUPPLY`,
    ///         which is also `immutable` and enforced by the clamp below.
    ///         No human admin can mint via this path.
    // slither-disable-next-line centralization-risk
    function awardMiningEmission(address to, uint256 amount) external onlyHashrate {
        // v8 derives `emitted` from totalSupply (single source of truth).
        // `_mint` below auto-updates totalSupply — no manual SSTORE needed.
        //
        // Robust cap clamp:
        //   1. `totalSupply()` MAY (in degenerate states) be < INITIAL_SUPPLY
        //      if real burns to address(0) occurred. With v8's constructor
        //      validating `protocolTreasury != address(0)`, every code-path that
        //      could route WHALE to the zero address is closed at deploy time.
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

    /// @notice Cumulative WHALE minted via mining emission so far. Derived from
    ///         `totalSupply() - INITIAL_SUPPLY` (no separate storage in v8).
    /// @dev    Cast to uint128 preserves the v7.x ABI signature (auto-generated
    ///         getter when `totalEmitted` was a `uint128 public` storage variable).
    ///         The cast is safe — value bounded by `MINING_MAX = 21M − 21K WHALE`,
    ///         well under `type(uint128).max`. Underflow guard mirrors
    ///         `awardMiningEmission` in case a degenerate state ever pushes `totalSupply`
    ///         below `INITIAL_SUPPLY`.
    function totalEmitted() external view returns (uint128) {
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

    /// @dev Returns `(whaleReserve, usdtReserve, blockTimestampLast)`. WHALE is token1 by
    ///      constructor invariant.
    function _getReserves() internal view returns (uint112 rWHALE, uint112 rUSDT, uint32 ts) {
        (uint112 r0, uint112 r1, uint32 t) = IPancakePair(pair).getReserves();
        return (r1, r0, t);
    }

    function _spotPrice() internal view returns (uint256) {
        (uint112 rWHALE, uint112 rUSDT,) = _getReserves();
        if (rWHALE == 0) return 0;
        return uint256(rUSDT) * 1e18 / uint256(rWHALE);
    }

    // ============================================================
    // _update hook — protocol heart
    //
    // Layer flow (numbers reflect runtime order):
    //   1  → 1.5 → 2  → 2.5 → 3   (preflight + system-address shorts)
    //   2.b                       (zap buy-tax exemption)
    //   6                         (reserves snapshot)
    //   7a (verify pending addLp + settle via hashrate.notifyCredit)
    //   8  (auto-harvest both sides; emission tick lives inside hashrate.notifyHarvest)
    //   7b (pair-burn reconcile + hashrate.notifyDebit)
    //   13 (TWAP cascade rotation)
    //   8e (peakTwap30d advance, pre-Layer-9)
    //   8c → 8d                   (staging maintenance + LP snapshot)
    //   9 → 10 (classify + tax + execute)
    //   11 (active-burn hook)
    //   12 (FOMO timer)
    //   ── post-pipeline (always runs) ──
    //   14 (magic-value referral binding via WHALE transfer)
    //   15 (POL flush trigger via ≥ POL_TRIGGER_AMOUNT to fomoVault, EOA-only)
    // ============================================================

    /// @dev ERC20 `_update` override is a thin wrapper around `_updateImpl`,
    ///      then a tail hook that drains the BurnVault / RefVault FIFO queue
    ///      whenever WHALE lands in either vault.
    ///
    ///      Why a wrapper:
    ///        - `_distributeDynamic` (WHALEHashrate) mints hierarchy-share residue
    ///          to RefVault via `whale.awardMiningEmission -> _mint -> _update(0, refVault, X)`.
    ///          Pre-wrapper this grew refVault reserve without paying out the
    ///          queue, so on a dead market (no sells) queued entries piled up
    ///          until a keeper intervened.
    ///        - External donations `whale.transfer(user, vault, X)` also pass
    ///          through this override and now drain the queue as a side effect.
    ///        - Any future code path that mints / transfers WHALE to a vault
    ///          inherits the drain automatically.
    ///
    ///      What this wrapper does NOT cover (and why it is fine):
    ///        - `_applySellTax` routes baseBurn / baseRef via `super._update`
    ///          (parent ERC20 `_update`), which bypasses this override entirely.
    ///          That path retains its own inline `try X.processQueue() {} catch {}`
    ///          calls (WHALE._applySellTax) - authoritative for sell-tax routing.
    ///
    ///      Reentrancy: `processQueue` is `nonReentrant` and pays out via
    ///      `token.transfer(user, amount)` which re-enters WHALE._update with
    ///      `from == vault`. Layer 2 catches `_isSystemAddress(from)` and
    ///      short-circuits via `super._update + return`, so the payout
    ///      transfer reaches the wrapper's tail with `to = user` (not vault)
    ///      and no recursion fires. `try/catch` further isolates queue
    ///      failures from the host transfer.
    function _update(address from, address to, uint256 value) internal override {
        _updateImpl(from, to, value);

        // Tail hook: drain vault FIFO on any inbound WHALE. `to` checked against
        // immutable refs (no SLOAD); branch elided for the common `to == pair`
        // / `to == user` paths after EVM jump prediction.
        if (to == address(burnVault)) {
            try burnVault.processQueue() {} catch {}
        } else if (to == address(refVault)) {
            try refVault.processQueue() {} catch {}
        }
    }

    function _updateImpl(address from, address to, uint256 value) private {
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

        // Layer 2.b: buy-tax exemption for the v9.x zap helper.
        //
        // When `from == pair && to == WHALE_ZAP_ROUTER`, the WHALE is en route to
        // the zap as part of its internal USDT->WHALE swap leg (driven by the
        // user's one-click zap call). Bypass the full pipeline: no buy tax,
        // no Layer 8 harvest for the zap, no FOMO trigger. The zap forwards
        // this WHALE into pair as the LP-add leg, where Method-B stages
        // `lastTransfer = WHALE_ZAP_ROUTER`. The subsequent Layer 7a settle
        // detects that staged identity and redirects credit to the actual
        // user (the zap's `pendingUser()`) — see `_settlePendingLpAdd`.
        //
        // The exemption is narrow: only the pair->zap direction. zap->user
        // or user->zap follow the normal pipeline. Pre-liquidity griefing
        // is naturally blocked by Pancake's div-by-zero on swap with empty
        // reserves.
        //
        // CRITICAL gate: only short-circuit when zap is currently executing
        // `zap()` (signalled by non-zero `pendingUser` in transient storage).
        // Without this check, `Router.removeLiquidity(USDT, WHALE, lp, 0, 0,
        // ZAP_ADDR, deadline)` would route the WHALE leg of pair.burn through
        // this short-circuit, bypassing Layer 6 burn detection and
        // `_reconcileLp`'s `hashrate.notifyDebit`. Attacker would keep
        // their LP's full hashrate AND retrieve the WHALE out of the zap via
        // a follow-up `zap.zap()` refund. The cross-call to `pendingUser`
        // is a `view` (no reentry vector). When zap is dormant, the
        // pair->zap transfer falls through to the normal pipeline, where
        // `_reconcileLp` reverts via gate 1 (`zap.registeredLp == 0`).
        if (from == pair && to == WHALE_ZAP_ROUTER && WHALE_ZAP_ROUTER != address(0)) {
            address inflight;
            try IWhaleZapRouter(WHALE_ZAP_ROUTER).pendingUser() returns (address u) {
                inflight = u;
            } catch {}
            if (inflight != address(0)) {
                super._update(from, to, value);
                return;
            }
            // else: zap not in-flight — fall through to normal pipeline.
            //       Burn detection + _reconcileLp gate 1 handles the rest.
        }

        // Layer 2.5: pair as from + value=0 short-circuit.
        //
        // OZ ERC20 `_spendAllowance` does NOT check allowance when value == 0, so anyone
        // can call `whale.transferFrom(pair, _, 0)` for free. Without this guard, value=0
        // transfers from pair would run the entire pipeline — exposing free triggers for
        // Layer 7a verify, Layer 8 mining, Layer 8e peakTwap30d, Layer 13 cascade rotation.
        if (from == pair && value == 0) {
            super._update(from, to, 0);
            return;
        }

        // Layer 3: pair uninitialised guard.
        //
        // Bootstrap `to == pair` (first-ever WHALE transfer to pair before pair.mint
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

        // (Layer 5 (pre-open `from == pair` revert) deleted in v9: trading is
        // live from constructor. Pre-liquidity swaps are blocked naturally by
        // Pancake's div-by-zero on empty reserves.)

        // (v8.x: Layer 5.5 active-burn cap moved into `_onActiveBurn` itself —
        // single source of truth for active-burn gating + reward, exercised at
        // Layer 11. Trade-off: revert path now wastes ~30K extra gas going through
        // Layers 6-10 first, but normal-path users never hit it.)

        // Layer 6: read pair state once. Reserves snapshot serves Layer 6 (spot),
        // Layer 8 (mining base), Layer 13 (priceCumulative extrapolation), and is
        // packed into a uint256 for `_verifyAndSettle` to avoid stack pressure.
        uint112 rWHALE;
        uint112 rUSDT;
        uint256 spotPriceNow;
        uint256 currentCum;
        {
            uint32 _ts;
            (rWHALE, rUSDT, _ts) = _getReserves();
            spotPriceNow = rWHALE > 0 ? uint256(rUSDT) * 1e18 / uint256(rWHALE) : 0;
            currentCum = _currentPriceCumulative(rWHALE, rUSDT, _ts);
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
        // WHALEHashrate. Logic shared with `_resolvePendingBeforePolOperation` via
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
        // lives inside WHALEHashrate; `notifyHarvest` self-ticks the emission curve at
        // its top, then materializes pending static + node rewards via callback to
        // `awardMiningEmission`. Idempotent within a block (subsequent ticks short-circuit on
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
        // is `nonReentrant` — recursion via awardMiningEmission → _mint → super._update(0,...)
        // → Layer 1 short-circuit cannot re-enter.
        if (from != pair) hashrate.notifyHarvest(from);
        if (to != pair && to != from) {
            hashrate.notifyHarvest(to);
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

        // Layer 13: TWAP cascade rotation. HOISTED before Layer 8c so non-Router
        // stage's tax-aware expectedLp reads the same TWAP cascade state Layer 9
        // will use.
        _maybeUpdateTwapSnapshots(currentCum);

        // Layer 8e: peak tracker advance BEFORE Layer 8c's tax-aware expectedLp
        // (non-Router) AND Layer 9's tax calc both read `_currentSellTaxBps`.
        _updatePeakTwap(currentCum);

        // Layer 8c: stage fresh pending on user→pair WHALE transfer.
        if (to == pair) {
            usdtBalance = _stagePending(value, kLastNow, totalLpNow, rWHALE, rUSDT, from, spotPriceNow);
        }

        // Layer 8d: LP state snapshot.
        if (totalLpNow != lastTotalLp) lastTotalLp = totalLpNow;
        if (kLastChanged) lastKLast = kLastNow;

        // Layer 9 + 10: classify + tax + route.
        (bool isBuy, bool isSell, uint256 sellPart) = _classifyAndRoute(
            from, to, value, rWHALE, rUSDT, spotPriceNow, usdtBalance, isBurnNow
        );

        // Layer 11: active burn hook.
        if (to == DEAD && from != pair) {
            _onActiveBurn(from, value, spotPriceNow);
        }

        // Layer 12: forward trade context to FomoVault.
        if (isBuy || isSell) {
            try fomoVault.notifyTrade(isBuy, isSell, value, sellPart, spotPriceNow) {} catch {}
        }

        // Layer 14: magic-value referral binding via WHALE transfer.
        //
        // Two paths, both gated on `msg.sender == from` to prevent allowance-based
        // force-binds (`transferFrom(victim, attackerUpline, 0/REFCODE)` with a
        // pre-granted allowance ≥ REFCODE_AMOUNT — bind is irreversible, so a
        // yield wrapper / DEX router with max approval could otherwise capture
        // victim into the attacker's subtree):
        //   (a) value == REFCODE_AMOUNT (0.001 WHALE) — token moves to upline.
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
        //     which propagate as well — hWHALE is a protocol-specific token
        //     where strict bind semantics outweigh probe-compatibility.
        if (msg.sender == from && (value == 0 || value == REFCODE_AMOUNT)) {
            try hashrate.notifyMagicBind(from, to) returns (bool) {} catch {}
        }

        // Layer 15: POL flush trigger via magic-value transfer
        // to fomoVault. Wallet `Send` of ≥ POL_TRIGGER_AMOUNT (0.001 WHALE) to
        // `fomoVault`:
        //   1. The transferred WHALE joins the FOMO pool (donation, already done
        //      by super._update inside Layer 9 above).
        //   2. `flushPolForUser(from)` runs: caller receives ≤0.5% of the POL
        //      buffer in WHALE.
        //
        // POSITION (post-pipeline): runs AFTER Layer 8 harvest, so a user with
        // pending mining rewards but zero hot WHALE balance can use the same tx
        // to (a) harvest mining rewards into balance, (b) auto-transfer the
        // 0.001 WHALE donation, (c) trigger the POL flush + receive the caller
        // reward. No early return — the transfer-side super._update has already
        // moved the value to fomoVault via Layer 9.
        //
        // Trigger is EOA-only and direct-transfer-only (v9):
        //   - `from == msg.sender` blocks `transferFrom` paths so the trigger
        //     can't be piggybacked onto an arbitrary user's allowance flow.
        //   - `tx.origin == msg.sender` blocks ordinary contract callers
        //     (MEV bots, batch routers) AND the constructor-bypass loophole:
        //     during a contract's constructor, `msg.sender = the contract
        //     being constructed`, while `tx.origin = the EOA that initiated
        //     the outer tx`. Those addresses can never be equal, so a CREATE2
        //     contract calling WHALE.transfer from inside its own constructor
        //     fails this check. Same for any contract that wraps the call —
        //     a wrapper's msg.sender to WHALE is itself, not the end-user EOA.
        //
        // v9 removed the v8 `msg.sender.code.length == 0` belt-and-braces
        // check — it was redundant with `tx.origin == msg.sender` and
        // false-rejected EIP-7702 delegated EOAs (`0xef0100…` prefix gives
        // them code.length > 0 but they're the actual user signer). 7702
        // users now harvest the POL trigger reward normally.
        //
        // The donation itself (super._update value transfer) still goes through
        // for any caller — only the flush-and-reward leg is gated.
        if (
            to == address(fomoVault)
                && value >= POL_TRIGGER_AMOUNT
                && from == msg.sender
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
    ///      `min(l0, l1)` formula (using POST-tax WHALE for non-Router callers
    ///      to mirror Layer 9's force-sell), and fires FOMO entry for
    ///      Router-only addLp. Returns `usdtBalance` (cached for Layer 9).
    function _stagePending(
        uint256 value,
        uint256 kLastNow,
        uint256 totalLpNow,
        uint112 rWHALE,
        uint112 rUSDT,
        address from,
        uint256 spotPriceNow
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
        // (`usdt.transfer + whale.transfer + pair.mint(self)` in a single tx) needs
        // their own `whale.transfer` to write the stage; otherwise the stage is
        // empty (or worse, set by a stale Router-staged attacker) and their LP
        // mint either earns no hashrate or is hijacked. We compute the post-tax
        // WHALE that will reach pair (Layer 9 force-sells non-Router), so
        // `expectedLp` matches the actual LP `pair.mint` will produce.
        //
        // Sell-with-donation residue: an attacker pre-donating USDT and then
        // doing a Router swap WILL write a stage with `expectedLp > 0` (the
        // Layer 9 lpPart classification can't distinguish swap-with-donation
        // from real addLp at hook time). Such stages persist briefly but get
        // cleared by the next from=pair op (Layer 7a settle's degenerate path
        // when `actualLpDelta == 0`) or overwritten by any subsequent legitimate
        // addLp. This is the v7.0 sell-tax-bypass known limit's tail; v8.1
        // WHALERouter will close both via `msg.sender == WHALERouter` gating.
        //
        // Trade-off: WHALE-first Router `addLiquidity(WHALE, USDT, ...)` (USDT NOT
        // arrived yet at WHALE transfer hook) loses credit. Frontends MUST use
        // USDT-first ordering — already documented requirement in CLAUDE.md.
        uint256 predicted = _predictMintFee(kLastNow, totalLpNow, rWHALE, rUSDT);
        if (predicted > type(uint96).max) predicted = type(uint96).max;

        // For non-Router post-trading transfers, Layer 9 will force-sell `value`
        // with the dynamic sell-tax rate. Predict the same rate here (Layer 8e
        // has been hoisted above so `_currentSellTaxBps` reads the same peak
        // state Layer 9 sees) so `valueIn` matches the WHALE that actually lands
        // in pair. Mirrors Layer 9's initial+post-spot recheck verbatim.
        uint256 valueIn = value;
        if (msg.sender != PANCAKE_ROUTER) {
            uint256 sellTaxBps = _currentSellTaxBps(spotPriceNow);
            {
                uint256 denom = uint256(rWHALE) + value;
                uint256 postSpot = denom == 0
                    ? 0
                    : spotPriceNow * uint256(rWHALE) / denom * uint256(rWHALE) / denom;
                uint256 postTax = _currentSellTaxBps(postSpot);
                if (postTax > sellTaxBps) sellTaxBps = postTax;
            }
            uint256 tax = value * sellTaxBps / 10_000;
            unchecked { valueIn = value - tax; }
        }

        uint256 expectedLp;
        if (usdtBalance > rUSDT) {
            // Same `min(l0,l1)` formula as PancakeV2's pair.mint. Post-transfer
            // WHALE balance is `super.balanceOf(pair) + valueIn` (super._update has
            // not run yet at this hook moment); for non-Router, `valueIn` is the
            // post-tax fraction that survives Layer 9's force-sell.
            uint256 whaleBalanceAfter = super.balanceOf(pair) + valueIn;
            uint256 whaleExcess = whaleBalanceAfter > uint256(rWHALE) ? whaleBalanceAfter - uint256(rWHALE) : 0;
            if (whaleExcess > 0) {
                uint256 newTs = totalLpNow + predicted;
                uint256 l0 = (usdtBalance - rUSDT) * newTs / uint256(rUSDT);
                uint256 l1 = whaleExcess * newTs / uint256(rWHALE);
                expectedLp = l0 < l1 ? l0 : l1;
            }
        }

        // v8.x.y: ALWAYS write the stage on a `to == pair` WHALE transfer. The
        // previous "expectedLp == 0 -> _clearStage()" gate (CRITICAL 2 fix)
        // mis-fired on Router WHALE-first `addLiquidity(WHALE, USDT, ...)`, where
        // USDT has not arrived at the WHALE transfer hook -> `usdtBalance == rUSDT`
        // -> `expectedLp = 0` -> stage cleared -> settle never credits the user.
        // Observed on BSC mainnet (user 0xF647C602...A4d): 114 LP held but
        // `registeredLp == 0`, LP un-burnable. Same root cause cascaded into:
        //   - WHALE-first addLp users earned no hashrate, LP became un-burnable
        //     (registeredLp == 0 trips `_reconcileLp` gate 1).
        //   - WHALE-first downlines never triggered the upline's ref reward
        //     (no notifyCredit path) nor updated `validDownlines` counter.
        //
        // The protection CRITICAL 2 was attempting (no phantom credit from
        // stale stage) is re-rooted in the settle path: `_settlePendingLpAdd`
        // early-returns and clears stage when `totalLpNow_ <= lastTotalLp_`
        // (no mint visible) or `userLpDelta == 0` (no LP minted to user).
        // Stage write without a follow-up mint is naturally garbage-collected
        // at the next from=pair op -> no false credit fires.
        //
        // For WHALE-first specifically, `pendingExpectedUserLp = 0` so the
        // verify gate (`pendingExpectedUserLp > 0` predicate) is skipped --
        // user trades C2 piggyback protection for credit-path correctness.
        // USDT-first ordering still gets full verify protection.
        //
        // Residual exposure (accepted): an attacker can donate WHALE to pair
        // while pre-stamping `lastTransfer = self`, then wait for a victim
        // to do USDT-only-then-`pair.mint(victim)` (an unusual call pattern
        // not emitted by canonical wallets) -- victim's `userLpDelta` would
        // credit to the attacker. Cost: attacker's donated WHALE is permanent
        // loss; gain: hashrate proportional to victim's USDT contribution.
        // v9 WhaleZapRouter's `msg.sender == WHALE_ZAP_ROUTER` gate + credit
        // pass-through closes this further for users routing through the zap.
        //
        // OVERWRITE -- repeated dust stages don't accumulate.
        //
        // uint96 overflow safeguard (defense-in-depth): WHALE total supply is
        // 21M = 2.1e25 wei → LP shares are bounded well under uint96.max
        // (≈ 7.9e28). Practical truncation is unreachable, but if a malformed
        // input ever produces a value above the cap (e.g., a future upgrade
        // path or factory misconfiguration), saturate to uint96.max instead
        // of silently truncating low bits — which would zero out the
        // `pendingExpectedUserLp > 0` verify gate and skip C2 piggyback
        // detection. Saturation keeps verify ARMED at the cap.
        uint256 cappedExpected = expectedLp > type(uint96).max ? type(uint96).max : expectedLp;
        uint256 cappedPredicted = predicted > type(uint96).max ? type(uint96).max : predicted;
        pendingMintFee = uint96(cappedPredicted);
        lastTransfer = from;
        pendingExpectedUserLp = uint96(cappedExpected);

        // FOMO entry fires HERE (at stage), not at settle, so the FOMO timer
        // reflects the user's commit moment instantly. Settle runs in a later
        // tx and may be after the timer would have expired, breaking FOMO's
        // commit-then-wait semantics.
        //
        // TWO PATHS qualify as Router-mediated addLp:
        //
        //   (a) Direct path — user calls Router.addLiquidity themselves.
        //       Router.transferFrom triggers Layer 8c with `from = user EOA`,
        //       `msg.sender = Router`. Gate: `tx.origin == from`. Manual-
        //       atomic addLp (no Router) does NOT match — those users still
        //       get hashrate/LP credit but skip FOMO.
        //
        //   (b) Zap path — user calls zap.zap() which internally calls
        //       Router.addLiquidity. Router.transferFrom triggers Layer 8c
        //       with `from = zap contract`. `tx.origin == from` fails (zap
        //       is not the EOA). Instead resolve the real user via the
        //       zap's transient `pendingUser()` view, then EOA-gate on
        //       `tx.origin == realUser`. This lets zap users participate
        //       in FOMO as themselves, mirroring the v9 credit pass-through
        //       used for hashrate at settle time.
        //
        // Both gates require:
        //   - `msg.sender == PANCAKE_ROUTER`: canonical-router LP-adders only.
        //   - `tx.origin == intended_lp_adder`: blocks contracts that wrap
        //     Router calls, and the constructor-bypass loophole (constructor
        //     msg.sender != tx.origin EOA).
        //
        // v9 removed the v8 `from.code.length == 0` belt-and-braces check —
        // redundant with `tx.origin == from` and false-rejected EIP-7702
        // delegated EOAs. 7702 users now participate in FOMO normally.
        //
        // Wrapped in try/catch — FOMO bookkeeping must never brick addLp.
        if (msg.sender == PANCAKE_ROUTER) {
            address fomoUser;
            if (from == WHALE_ZAP_ROUTER && WHALE_ZAP_ROUTER != address(0)) {
                // Path (b): zap routing. pendingUser is the real EOA;
                // tx.origin gate prevents wrapped/contract callers.
                address realUser;
                try IWhaleZapRouter(WHALE_ZAP_ROUTER).pendingUser() returns (address u) {
                    realUser = u;
                } catch {}
                if (realUser != address(0) && tx.origin == realUser) {
                    fomoUser = realUser;
                }
            } else if (tx.origin == from) {
                // Path (a): standard Router-atomic addLp from an EOA.
                fomoUser = from;
            }

            if (fomoUser != address(0)) {
                // fomoEqv = predicted user share of post-mint USDT reserve.
                // Equivalent to `expectedLp × usdtBalance / (TS_now + feeMint + expectedLp)`.
                // Matches the settle-time `userLpDelta × useRUsdt / stageTs` formula
                // up to the predicted-vs-realized drift (≤ 1-2 wei for Router atomic).
                uint256 newTsPostMint = totalLpNow + predicted + expectedLp;
                uint256 fomoEqv;
                unchecked {
                    fomoEqv = expectedLp * usdtBalance / newTsPostMint;
                }
                try fomoVault.notifyLpAdd(fomoUser, fomoEqv) {} catch {}
            }
        }
    }

    /// @dev Two-branch burn detection used by Layer 6 / Layer 7b.
    ///
    /// (a) USDT balance signal: `pair.burn` transfers USDT out BEFORE the WHALE leg.
    /// (b) totalLp strict decrease: covers net-negative piggyback where attacker's
    ///     burn exceeds alice's mint.
    ///
    /// burnLiquidity uses max of two formulas for exactness:
    ///   (a) `value × totalLpNow / (balanceWHALE - value)` — algebraically inverts
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
            uint256 balanceWHALE = super.balanceOf(pair);
            uint256 fromFormula;
            if (balanceWHALE > value) {
                fromFormula = value * totalLpNow_ / (balanceWHALE - value);
            }
            uint256 fromDelta = lastTotalLp_ > totalLpNow_ ? lastTotalLp_ - totalLpNow_ : 0;
            burnLiquidity = fromFormula > fromDelta ? fromFormula : fromDelta;
        }
    }

    /// @dev Layer 7a / POL-callback shared settlement. Wraps the cross-call to
    ///      WHALEHashrate's `notifyCredit` with current pair reserves passed through.
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

        // Cross-call into WHALEHashrate. notifyCredit:
        //   - increments `registeredLp[user]`
        //   - mints hashrate (= 2 × userLpDelta × useRUsdt / stageTs)
        //   - propagates upline state via Step 4 of its _update
        //   - RETURNS (refToReward, hashrateUsed) for one-shot reward decision
        // notifyCredit is `nonReentrant` and `onlyWHALE`. The return-value pattern
        // collapses what was previously a callback (hashrate→whale.queueReferralReward)
        // into a direct call from WHALE — only WHALE fires `refVault.triggerReward`,
        // and ONLY on the LP-backed addLp path (this function). transferHashrate /
        // bind back-credit can never produce a non-zero refToReward.
        //
        // v9.x zap-router credit pass-through: when the zap helper is the staged
        // WHALE-adder of record (it just transferred WHALE into pair on behalf of a
        // user), redirect the credit to the actual user. The zap exposes
        // `pendingUser()` for this single tx; WHALE cross-calls it once. Refund
        // semantics for the LP token already routed correctly (Router.addLiquidity
        // sent LP to the user via `to = msg.sender`), so registeredLp/hashrate
        // align with pair.balanceOf for the real user. Zero-address fallback
        // (zap misconfigured / called externally) credits the zap, where the
        // hashrate is stranded but doesn't break invariants.
        address creditUser = lastTransfer_;
        if (creditUser == WHALE_ZAP_ROUTER) {
            // try/catch so a misconfigured / self-destructed zap can never
            // brick Method-B settle. Fallback: credit stays at zap (hashrate
            // stranded but no revert).
            try IWhaleZapRouter(WHALE_ZAP_ROUTER).pendingUser() returns (address realUser) {
                if (realUser != address(0)) creditUser = realUser;
            } catch {}
        }
        (address refToReward, uint256 hashrateUsed) =
            hashrate.notifyCredit(creditUser, userLpDelta, useRUsdt, stageTs);

        // One-shot referral reward (LP-backed only). Inlined here from the deleted
        // `queueReferralReward` external. Computes USDT→WHALE at max(spot, TWAP_30min)
        // and queues into RefVault. Wrapped in try/catch — RefVault is a
        // side-effect queue; a vault revert here would brick every addLp settle.
        if (refToReward != address(0)) {
            uint256 rewardUsdt = hashrateUsed * REF_REWARD_BPS / 10_000;
            if (rewardUsdt > REF_REWARD_CAP_USDT) rewardUsdt = REF_REWARD_CAP_USDT;
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

    /// @dev Splits an WHALE → pair transfer into "sell" vs "LP-leg". `usdtBalance` is
    ///      pre-computed in Layer 8c to avoid a second `USDT.balanceOf(pair)` read.
    function _splitSellAndLp(uint256 value, uint112 rWHALE, uint112 rUSDT, uint256 usdtBalance)
        internal
        view
        returns (uint256 sellPart)
    {
        uint256 usdtDelta = usdtBalance > rUSDT ? usdtBalance - rUSDT : 0;

        uint256 lpPart;
        if (usdtDelta > 0 && rUSDT > 0) {
            uint256 whaleBalance = super.balanceOf(pair);
            uint256 whaleDelta = whaleBalance > rWHALE ? whaleBalance - rWHALE : 0;
            if (usdtDelta * uint256(rWHALE) > whaleDelta * uint256(rUSDT)) {
                uint256 expectedWHALE = usdtDelta * uint256(rWHALE) / uint256(rUSDT);
                if (expectedWHALE > whaleDelta) {
                    lpPart = expectedWHALE - whaleDelta;
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
        uint112 rWHALE,
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
                sellPart = _splitSellAndLp(value, rWHALE, rUSDT, usdtBalance);
            } else {
                sellPart = value;
            }

            if (sellPart > 0) {
                sellTaxRate = _currentSellTaxBps(spotPriceNow);
                // Anti first-dumper advantage: re-evaluate at projected post-sell spot.
                {
                    uint256 denom = uint256(rWHALE) + sellPart;
                    uint256 postSpot =
                        spotPriceNow * uint256(rWHALE) / denom * uint256(rWHALE) / denom;
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
    ///      Reentrancy safety: vault payouts re-enter WHALE._update with `from = vault`,
    ///      which Layer 2 catches and short-circuits to plain super._update.
    function _applySellTax(address seller, uint256 tax, uint256 taxBps) internal {
        uint256 basePart = tax * SELL_TAX_BASE_BPS / taxBps;
        uint256 dynPart = tax - basePart;

        // Base: 20/40/40 dev/burn/ref. Residue to ref.
        uint256 baseDev = basePart * SELL_BASE_DEV_PCT / 100;
        uint256 baseBurn = basePart * SELL_BASE_BURN_PCT / 100;
        uint256 baseRef = basePart - baseDev - baseBurn;

        if (baseDev > 0) {
            // `protocolTreasury` is `immutable` (set at construction, never re-assignable).
            // It receives a fixed 20% of the base sell-tax slice. No admin can
            // change the recipient or the percentage; both are deploy-time
            // constants. CertiK / Slither flagging this as "fee-to-fixed-
            // recipient centralization" is by-design and bounded.
            // slither-disable-next-line centralization-risk
            super._update(seller, protocolTreasury, baseDev);
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
        (uint112 rWHALE, uint112 rUSDT, uint32 ts) = _getReserves();
        uint256 spotPrice = rWHALE > 0 ? uint256(rUSDT) * 1e18 / uint256(rWHALE) : 0;
        uint256 currentCum = _currentPriceCumulative(rWHALE, rUSDT, ts);

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
    ///        - `from == pair`: only check during pair-originating WHALE transfers (buy/burn).
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
            // Only USDT-side reserve is needed: WHALEHashrate's notifyCredit computes
            // `2 × lpDelta × stageReserveUsdt / stageTotalLp` (the WHALE side is
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
    ///      the user destroys WHALE to DEAD and receives 1.3× back from BurnVault — net
    ///      0.3× extracted per cycle, paid from sell-tax accumulated in the vault.
    ///      Single source of truth for both the per-call hard cap (10 WHALE — revert)
    ///      and the per-call min entry (1 USDT-eq — silent skip).
    function _onActiveBurn(address user, uint256 burnedAmount, uint256 spotPrice) internal {
        // Hard cap: any single active-burn > 10 WHALE reverts. Users wanting to
        // destroy more must split into multiple txs (also bounds vault drain rate).
        if (burnedAmount > ACTIVE_BURN_MAX_WHALE) revert ActiveBurnTooLarge();

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
    // WHALEHashrate now. WHALE retains only the cap clamp inside `awardMiningEmission`.
    // External callers wanting the daily emission projection should query
    // `hashrate.dailyEmission()` instead.

    // ============================================================
    // TWAP
    // ============================================================

    /// @dev Reserves + ts threaded in by callers (Layer 6 captures them once for the
    ///      whole `_update`). token0 is USDT → pass `rUSDT` (= r0) and `rWHALE` (= r1).
    function _currentPriceCumulative(uint112 rWHALE, uint112 rUSDT, uint32 ts)
        internal
        view
        returns (uint256)
    {
        uint256 cum = IPancakePair(pair).price1CumulativeLast();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - ts;
            if (elapsed > 0 && rUSDT > 0 && rWHALE > 0) {
                uint256 spotQ112 = (uint256(rUSDT) << 112) / rWHALE;
                cum += spotQ112 * elapsed;
            }
        }
        return cum;
    }

    function _calculateTwap(TwapSnapshot memory snap) internal view returns (uint256) {
        (uint112 rWHALE, uint112 rUSDT, uint32 ts) = _getReserves();
        return _calculateTwapWithCum(snap, _currentPriceCumulative(rWHALE, rUSDT, ts));
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
    ///         live by `WHALEHashrate.pendingRewards(account)`. Wallets / DEX UIs
    ///         see "spendable balance = perceived balance" without needing to
    ///         simulate `claim()` off-chain.
    ///
    ///         System addresses (`this`, vaults, pair, hashrate, DEAD) return raw
    ///         (they don't accumulate hashrate-derived pending; the cross-call
    ///         would always return 0, so we skip it for gas).
    ///
    ///         Internal WHALE code that needs the true `_balances[u]` value uses
    ///         `super.balanceOf(...)` directly (e.g., LP-leg WHALE delta read in
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

    /// @notice Returns the predicted hashrate that will be minted to the currently-
    ///         staged user (`lastTransfer`) when settle fires. Used by
    ///         `WHALEHashrate.pendingRewards` to display unsettled mining accrual to
    ///         users in the [Layer 8c stage, Layer 7a settle] window.
    ///
    ///         Mirrors `notifyCredit`'s `hashAmount = 2 × lpDelta × rUsdt / TS`.
    ///         The 2× factor: `hashrate = WHALE_part × TWAP + USDT_part` and
    ///         `WHALE_part × TWAP ≈ USDT_part` for a balanced add at spot, so
    ///         total = 2 × USDT_part = 2 × user_lp_share × rUsdt.
    ///
    ///         Returns 0 when nothing is staged or pair has zero supply.
    function estimatedStagedHashrate() external view returns (uint256) {
        address staged = lastTransfer;
        uint256 expectedLp = pendingExpectedUserLp;
        if (staged == address(0) || expectedLp == 0) return 0;

        (uint112 r0, , ) = IPancakePair(pair).getReserves();
        if (r0 == 0) return 0;

        uint256 ts = IERC20(pair).totalSupply();
        if (ts == 0) return 0;

        // 2 × lpDelta × rUSDT / TS — same formula `notifyCredit` runs at settle.
        return (2 * expectedLp * uint256(r0)) / ts;
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
