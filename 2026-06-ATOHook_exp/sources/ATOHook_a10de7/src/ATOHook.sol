// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    跡 (ato) jp. “a trace — the mark left behind” · a curve that retraces

    https://at0.io
    https://x.com/at0dev

        ato  ·  bonding curve

    21m ┤                                                             ∞  800x
        │                               ┊                    ╭────────╯
        │                               ┊            ╭───────╯      ╭╯
        │                               ┊     ╭──────╯       ╭╮    ╭╯
    15m ┤                              ╭◯─────╯             ╭╯│   ╭╯     600x
        │                        ╭─────╯┊                  ╭╯ │ ╭─╯
        │                   ╭────╯      ┊           ╭╮   ╭─╯  │╭╯
    10m ┤              ╭────╯           ┊         ╭─╯│  ╭╯    ╰╯         400x
        │          ╭───╯                ┊        ╭╯  │╭─╯
        │       ╭──╯                    ┊ ╭─╮  ╭─╯   ╰╯
        │     ╭─╯                  ╭╮   ◯─╯ │╭─╯
     5m ┤   ╭─╯                 ╭──╯│ ╭─╯   ╰╯                           200x
        │ ╭─╯            ╭─╮  ╭─╯   ╰─╯ ┊
        │ │      ╭╮  ╭───╯ ╰──╯         ┊
        │●╯──────╯╰──╯
      0 └──────────────────┴───────────────────┴──────────────────┴───── Ξ
                          500                 1000               1500

        ╭─ mint curve      ╭╮ price (sawtooth)      ┊◯ deprecation

    ato is an ERC-20 minted along a bonding curve embedded in a Uniswap v4 hook.
    The hook is the sole counterparty — every buy mints along a forward curve and
    every sell redeems along its inverse, paid from a reserve the hook holds.
    Supply approaches a hard asymptote of 21,000,000 and never reaches it;
    price rises exponentially with cumulative ETH and retraces ~50% at each halving
    of remaining supply — the trace the curve leaves behind.

    The retrace is not incidental: it is the engine that makes mining yield and
    LP volume work.
*/

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BaseHook} from "./BaseHook.sol";
import {CurveAccountant} from "./CurveAccountant.sol";
import {ATO} from "./ATO.sol";
import {IWeightAuthority} from "./interfaces/IWeightAuthority.sol";

/// @title  ATOHook — the bonding curve AND the reward stream as a single Uniswap v4 hook
/// @notice The pool holds NO external liquidity (`beforeAddLiquidity` reverts). `beforeSwap`
///         intercepts every swap, prices it on the curve (CurveAccountant), and returns a
///         BeforeSwapDelta that makes the hook the counterparty (the CL swap is no-op'd).
///         Exact-input only. ETH = currency0 (address(0)), ATO = currency1;
///         zeroForOne ⇒ BUY (ETH→ATO).
///
///         **Unified reward layer (mining-spec §2/§4):** the RewardStreamer is folded
///         into this hook, so the trading fee + realized Phase-2 surplus accrue into a Synthetix
///         `StakingRewards` ETH stream WITHOUT ever leaving the hook (the fee ETH is already raw
///         here; accrual is pure internal accounting — no external call, no transfer). The stream
///         drips **linearly over a trailing 7-day window** to stake weight (NOT instant); a 6-block
///         hold + no-staker buffer + bank-on-exit are preserved exactly. Stakers stake ATO into the
///         hook (custodial, tier-1); the LP manager reports tier-2/3 deposit-basis via add/removeWeight;
///         `getReward` pays ETH directly from the hook (pull, CEI).
///
/// @dev    ETH is held as RAW ETH on this contract, with three
///         disjoint counters that PARTITION the balance (the 3rd, `rewardPool`, is DERIVED, not stored):
///           address(this).balance == reserve + feesAccrued + rewardPool
///         A raw ETH donation is folded into the reward stream ON ARRIVAL (`receive`), so it lands in
///         `rewardPool` immediately and the partition holds by construction.
///         — `reserve` backs redemptions (the §5.4 cap means a redeem never pays more than `reserve`,
///           so reward ETH is NEVER touched by a sell); `feesAccrued` is fee ETH not yet folded into
///           the stream (≈0 between swaps — every swap sweeps it);
///         ATO uses a DEFERRED-BURN QUEUE: a sell parks the incoming ATO as a 6909 claim (UR-safe —
///         `mint` needs no float at beforeSwap, since the seller settles only at lock close) and burns
///         the PRIOR backlog, whose tokens are already settled and physically present. Buys mint fresh
///         ATO. The lagged burn keeps `ATO.totalSupply() == totalMinted + atoClaims`, with `atoClaims`
///         == the last sell awaiting burn.
contract ATOHook is BaseHook, CurveAccountant, ReentrancyGuard, IWeightAuthority {
    using FixedPointMathLib for uint256;

    ATO public immutable ato;
    Currency public immutable atoCurrency;
    Currency internal immutable ethCurrency; // address(0) — raw native take/settle
    uint256 internal immutable ATO_ID; // 6909 id for the ATO burn-queue

    /// @notice ATO repurchased on sells, parked as 6909 claims, queued for the lagged real burn
    ///         (== the most recent sell awaiting burn under the flush-on-sells policy).
    uint256 public atoClaims;

    /// @dev Admin authority; gates the two one-shot setters — `setLPManager` (wiring) and `startMinting`
    ///      (the launch switch) — so they can't be front-run with a malicious weight-granter / premature
    ///      launch. Passed EXPLICITLY at construction (not `msg.sender`) so the hook can be deployed via a
    ///      CREATE3 factory — where the ctor `msg.sender` is the ephemeral proxy. NOT immutable:
    ///      `renounceDeployer()` zeroes it post-launch to go fully trustless (then both setters are
    ///      permanently uncallable). It is the ONLY admin authority — there is no pause/upgrade/withdraw.
    address public deployer;

    /// @dev The ONE pool this hook serves. `beforeInitialize` rejects any other key, so no
    ///      second pool can reuse the hook and corrupt the shared curve state.
    uint24 internal constant CANON_FEE = 0;
    int24 internal constant CANON_TICK_SPACING = 60;

    /*//////////////////////////////////////////////////////////////
                      REWARD STREAM (Synthetix, native ETH)
    //////////////////////////////////////////////////////////////*/

    uint256 public constant REWARDS_DURATION = 7 days; // trailing stream window (mining-spec §9.4)
    uint256 public constant HOLD_BLOCKS = 6; // weight-granting deposits lock for 6 blocks (§4.2)
    uint256 internal constant WAD = 1e18;

    address public lpManager; // tiers 2/3 weight authority; set once, post-deploy

    /// @dev Launch gate. FALSE on deploy ⇒ the curve is inert (`beforeSwap` reverts `MintNotLive`); the
    ///      deployer flips it on ONCE via `startMinting()`. One-way (no pause/close), so it can delay the
    ///      start but never halt a live market. Pairs with the terminal `mintClosed` latch: the curve is
    ///      live ⇔ `mintLive && !mintClosed`.
    bool public mintLive;

    // --- Synthetix accumulator ---
    uint256 public periodFinish; // stream end timestamp
    uint256 public rewardRate; // wei per second
    uint256 public lastUpdateTime; // last accumulator touch
    uint256 public rewardPerTokenStored; // accumulator (scaled 1e18)
    uint256 public buffered; // parked ETH while totalWeight == 0 (§6.1)

    uint256 public totalWeight; // Σ weight across all users (tier-1 + LP basis)
    mapping(address => uint256) public weight; // unified earning weight
    mapping(address => uint256) public tier1Staked; // custodial ATO subset of weight
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // accrued, claimable ETH
    mapping(address => uint256) public depositBlock; // 6-block hold stamp (single, per §9 lock)

    /*//////////////////////////////////////////////////////////////
                               EVENTS / ERRORS
    //////////////////////////////////////////////////////////////*/

    error ExactOutputUnsupported();
    error WrongPool();
    error NoLiquidity();
    error AmountOverflow();
    error NotDeployer();
    error MintNotLive(); // curve not launched yet (mintLive == false)
    error ZeroAddress();
    // reward-layer
    error NotLPManager();
    error AlreadySet();
    error ZeroAmount();
    error ExceedsStake();
    error ExceedsLpWeight();
    error HoldNotElapsed();
    error TransferFailed();

    event RewardAccrued(uint256 fee, uint256 surplus); // fee + realized surplus folded into the stream
    event RewardDonated(address indexed from, uint256 amount); // raw ETH donated to the hook, folded on receipt
    event RewardParked(uint256 amount); // buffered while no stakers (§6.1)
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event WeightAdded(address indexed user, uint256 basis);
    event WeightRemoved(address indexed user, uint256 basis);
    event UnstakedFor(address indexed user, uint256 amount, address indexed to); // tier-1 → LP move (§5.3)
    event LPManagerSet(address indexed lpManager);
    event MintStarted(); // the deployer opened the launch gate (one-way)
    event DeployerRenounced(); // the deployer relinquished admin authority for good

    /// @param ato_   the ATO token (deployed separately, e.g. via CREATE3, with THIS hook's precomputed
    ///               address as its minter). Decoupled from `new ATO` so ATO can carry its own vanity salt.
    /// @param admin_ the gated-setter authority (the deploying EOA) — see `deployer`.
    constructor(IPoolManager poolManager_, ATO ato_, address admin_) BaseHook(poolManager_) {
        if (address(ato_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        ato = ato_;
        atoCurrency = Currency.wrap(address(ato_));
        ethCurrency = Currency.wrap(address(0));
        ATO_ID = uint256(uint160(address(ato_)));
        deployer = admin_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true; // lock to the single canonical pool
        p.beforeAddLiquidity = true; // revert: the hook is the sole counterparty
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true; // custom accounting
    }

    /// @dev Permit ONLY the canonical ETH/ATO pool to bind this hook. Without this, anyone
    ///      could initialize a second pool (same currencies, different fee/tickSpacing → distinct
    ///      PoolId) that routes through the hook and mutates the shared mintCursor/reserve/etc.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(ato)
                || key.fee != CANON_FEE || key.tickSpacing != CANON_TICK_SPACING
        ) revert WrongPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No external liquidity is ever permitted in the curve pool.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert NoLiquidity();
    }

    /// @notice Sole-counterparty swap. Mints (buy) or burns (sell) along the curve and returns
    ///         the delta that absorbs the swap. Exact-input only. After pricing, the trading fee and
    ///         any newly-realized Phase-2 surplus are folded into the rolling 7-day reward stream —
    ///         pure internal accounting (the ETH is already raw on the hook).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(ato)) {
            revert WrongPool();
        }
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported(); // exact-input only
        if (!mintLive) revert MintNotLive(); // launch gate: the curve is inert until the deployer starts it

        uint256 amountIn = uint256(-params.amountSpecified);
        // specified = -amountSpecified: no-ops the CL swap (amountToSwap→0) and accounts the full input.
        int128 specifiedDelta = _toI128(amountIn);

        if (params.zeroForOne) {
            // BUY: ETH in → ATO out. Capture the input as RAW ETH on the hook (its reserve + fee) and
            // mint fresh ATO to the swapper. The `take` borrows the manager's native-ETH float and is
            // repaid when the swapper settles at lock close.
            (uint256 tokensOut,) = _processBuy(amountIn);
            poolManager.take(ethCurrency, address(this), amountIn);
            poolManager.sync(atoCurrency);
            ato.mint(address(poolManager), tokensOut);
            poolManager.settle();
            _accrueRewards(); // fold the just-skimmed fee + any realized surplus into the 7-day stream
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, -_toI128(tokensOut)), 0);
        } else {
            // SELL: ATO in → ETH out. Pay ETH raw from the hook's reserve. We can't take the seller's
            // ATO (not settled until lock close), so PARK it as a 6909 claim and burn the PRIOR backlog
            // instead — those tokens are already settled and present, so the burn needs no float and
            // never reverts (deferred-burn queue).
            (uint256 ethOut,) = _processSell(amountIn);
            uint256 backlog = atoClaims; // prior parked sells — settled, physically in the manager

            // park the incoming ATO as a claim (backed when the seller settles at lock close)
            poolManager.mint(address(this), ATO_ID, amountIn);
            atoClaims = backlog + amountIn;

            // pay ETH out raw; sync(0) resets the synced currency to native so settle{value} is safe
            poolManager.sync(ethCurrency);
            poolManager.settle{value: ethOut}();

            // lagged real burn of the prior backlog (delta-neutral on the swap)
            _burnBacklog(backlog);

            _accrueRewards(); // fold the redeem fee + any realized surplus into the 7-day stream
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, -_toI128(ethOut)), 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 REWARD ACCRUAL (mining-spec §1/§7 — internal)
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless skim of any pending trading fee + realized Phase-2 surplus into the reward
    ///         stream. Idempotent: every swap already calls `_accrueRewards` internally, so between swaps
    ///         this is a no-op (nothing new accrues without a swap). Kept so surplus can also be folded
    ///         out-of-band, and as a stable, named trigger for tooling/UX.
    /// @dev    No external call, no ETH transfer — the fee/surplus ETH is already raw on the hook; this
    ///         (re)starts the 7-day stream.
    function skim() external nonReentrant returns (uint256 amount) {
        return _accrueRewards();
    }

    /// @dev Fold the accrued trading fee + realized surplus into the rolling stream. Called at the end of
    ///      every swap (and by `skim`). Solvency: `surplus()` is conservative (`reserve − liability − dust`),
    ///      so reclassifying it leaves `reserve ≥ liability`; fees never backed the curve.
    function _accrueRewards() internal returns (uint256 amount) {
        uint256 fee = feesAccrued;
        uint256 surp = surplus(); // conservative realized surplus (≥0), withholds a dust margin
        amount = fee + surp;
        if (amount == 0) return 0;

        // Reclassify within the balance partition (no ETH leaves the hook).
        feesAccrued = 0; // fee ETH moves into the reward stream
        reserve -= surp; // realized free ETH skimmed; reserve stays ≥ liability + margin

        _foldIntoStream(amount); // (re)start the 7-day window over leftover + new (or park if no stakers)
        emit RewardAccrued(fee, surp);
    }

    /// @dev Fold `amount` ETH into the Synthetix stream. Settles the accumulator first. If there is no
    ///      stake weight, parks it in `buffered` (§6.1) to (re)start when the first staker arrives.
    function _foldIntoStream(uint256 amount) internal {
        _updateReward(address(0));
        if (totalWeight == 0) {
            buffered += amount; // §6.1: park; stream when the first staker arrives
            emit RewardParked(amount);
            return;
        }
        _startStream(amount);
    }

    /// @dev (Re)start/extend the stream over a fresh window, folding any in-flight leftover.
    ///      Caller must have settled the accumulator (`_updateReward`) first.
    function _startStream(uint256 reward) internal {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / REWARDS_DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + leftover) / REWARDS_DURATION;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARDS_DURATION;
    }

    /// @dev Called when `totalWeight` has just dropped to 0: freeze the stream and park the un-emitted
    ///      remainder so it isn't orphaned (§6.1). Caller ran `_updateReward` first, so everyone is
    ///      credited up to `min(now, periodFinish)`.
    function _bankRemainder() internal {
        if (block.timestamp < periodFinish) {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            if (remaining != 0) {
                buffered += remaining;
                emit RewardParked(remaining);
            }
        }
        rewardRate = 0;
        periodFinish = block.timestamp;
    }

    /// @dev Flush parked rewards into a fresh stream now that there is weight to earn it.
    function _flushBufferIfAny() internal {
        uint256 b = buffered;
        if (b != 0) {
            buffered = 0;
            _startStream(b);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ACCUMULATOR (views)
    //////////////////////////////////////////////////////////////*/

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalWeight == 0) return rewardPerTokenStored;
        uint256 delta = lastTimeRewardApplicable() - lastUpdateTime;
        if (delta == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + FixedPointMathLib.fullMulDiv(delta * rewardRate, WAD, totalWeight);
    }

    function earned(address account) public view returns (uint256) {
        uint256 perToken = rewardPerToken() - userRewardPerTokenPaid[account];
        return FixedPointMathLib.fullMulDiv(weight[account], perToken, WAD) + rewards[account];
    }

    function weightOf(address account) external view returns (uint256) {
        return weight[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * REWARDS_DURATION;
    }

    /// @notice Committed reward-stream ETH (streaming + buffered + earned-but-unclaimed), DERIVED as the
    ///         balance residual after redemption backing (`reserve`) and unswept fees (`feesAccrued`) — NOT
    ///         stored, so the 3-way partition `balance == reserve + feesAccrued + rewardPool` holds by
    ///         construction. Reverts if the hook is ever insolvent (balance < reserve + feesAccrued), so any
    ///         read doubles as a solvency tripwire. Donations are folded on arrival (`receive`), keeping this
    ///         residual consistent with the accumulator. `getReward` pays from it; the §5.4 redeem cap keeps
    ///         redemptions off it, so the two pools stay disjoint.
    function rewardPool() public view returns (uint256) {
        return address(this).balance - reserve - feesAccrued;
    }

    /// @dev Settle the accumulator and credit `account`'s pending rewards. Runs on every
    ///      state-changing reward entry, before weight changes.
    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          TIER 1 — custodial ATO stake
    //////////////////////////////////////////////////////////////*/

    function stake(uint256 amount) external nonReentrant {
        _updateReward(msg.sender);
        if (amount == 0) revert ZeroAmount();
        bool wasEmpty = totalWeight == 0;

        tier1Staked[msg.sender] += amount;
        weight[msg.sender] += amount;
        totalWeight += amount;
        depositBlock[msg.sender] = block.number; // arm the hold

        SafeTransferLib.safeTransferFrom(address(ato), msg.sender, address(this), amount);
        if (wasEmpty) _flushBufferIfAny(); // §6.1: bootstrapping staker starts the parked stream
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant {
        _updateReward(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (amount > tier1Staked[msg.sender]) revert ExceedsStake();
        _enforceHold(msg.sender);

        tier1Staked[msg.sender] -= amount;
        weight[msg.sender] -= amount;
        totalWeight -= amount;
        if (totalWeight == 0) _bankRemainder();

        SafeTransferLib.safeTransfer(address(ato), msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Pull accrued ETH rewards. CEI + nonReentrant; paid from the reward residual (`rewardPool()`),
    ///         which the §5.4 redeem cap keeps disjoint from `reserve`.
    function getReward() public nonReentrant returns (uint256 reward) {
        _updateReward(msg.sender);
        reward = rewards[msg.sender];
        if (reward != 0) {
            rewards[msg.sender] = 0; // effects ...
            (bool ok,) = msg.sender.call{value: reward}(""); // ... then interaction
            if (!ok) revert TransferFailed();
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Convenience: withdraw all tier-1 stake and claim. (Hold still applies.)
    function exit() external {
        withdraw(tier1Staked[msg.sender]);
        getReward();
    }

    /*//////////////////////////////////////////////////////////////
                       TIERS 2/3 — LP-manager weight hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time wiring of the LP manager (tiers 2/3 weight authority). Deployer-gated to prevent
    ///         a front-run that would install a malicious weight-granter.
    function setLPManager(address m) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (lpManager != address(0)) revert AlreadySet();
        if (m == address(0)) revert ZeroAddress();
        lpManager = m;
        emit LPManagerSet(m);
    }

    /// @notice Open the launch gate — minting (and thus the whole curve) becomes available. Deployer-gated
    ///         and ONE-WAY (no pause/close), so the curve deploys inert and the team flips it live exactly
    ///         once, when ready. Until then `beforeSwap` reverts `MintNotLive`.
    function startMinting() external {
        if (msg.sender != deployer) revert NotDeployer();
        if (mintLive) revert AlreadySet();
        mintLive = true;
        emit MintStarted();
    }

    /// @notice Permanently relinquish admin authority: sets `deployer` to address(0), making BOTH gated
    ///         setters (`setLPManager`, `startMinting`) uncallable forever — the hook becomes fully trustless
    ///         (it has no pause/upgrade/withdraw, so there is zero privileged surface afterward). Requires the
    ///         curve to already be live (`mintLive`) so renouncing can never brick the launch.
    function renounceDeployer() external {
        if (msg.sender != deployer) revert NotDeployer();
        if (!mintLive) revert MintNotLive(); // must launch before renouncing, else minting is bricked forever
        deployer = address(0);
        emit DeployerRenounced();
    }

    /// @notice Credit deposit-basis weight for an LP position (mining-spec §4). onlyLPManager.
    function addWeight(address user, uint256 basis) external nonReentrant {
        _updateReward(user);
        if (msg.sender != lpManager) revert NotLPManager();
        if (basis == 0) revert ZeroAmount();
        bool wasEmpty = totalWeight == 0;

        weight[user] += basis;
        totalWeight += basis;
        depositBlock[user] = block.number; // arm the hold

        if (wasEmpty) _flushBufferIfAny();
        emit WeightAdded(user, basis);
    }

    /// @notice Remove deposit-basis weight on LP liquidity removal (decrement-on-close, §4.1).
    ///         onlyLPManager. Enforces the 6-block hold and cannot eat into tier-1 weight.
    function removeWeight(address user, uint256 basis) external nonReentrant {
        _updateReward(user);
        if (msg.sender != lpManager) revert NotLPManager();
        if (basis == 0) revert ZeroAmount();
        if (basis > weight[user] - tier1Staked[user]) revert ExceedsLpWeight();
        _enforceHold(user);

        weight[user] -= basis;
        totalWeight -= basis;
        if (totalWeight == 0) _bankRemainder();

        emit WeightRemoved(user, basis);
    }

    /// @notice Atomically move `amount` of `user`'s tier-1 custodial stake OUT to `to` (the LP manager)
    ///         so it can be redeployed as a secondary-pool LP position in ONE tx (no unstake→redeposit
    ///         round-trip). onlyLPManager. The manager passes `msg.sender` as `user`, so a caller can only
    ///         ever move their OWN stake. Mirrors `withdraw`'s tier-1 effects (settle rewards, decrement
    ///         tier1Staked/weight/totalWeight, bank-remainder if totalWeight hits 0) BUT deliberately runs
    ///         **no source-hold check**: the manager re-adds curve-weight via `addWeight` in the SAME tx
    ///         (arming a FRESH 6-block hold on the resulting position), so there is no reward gap to JIT —
    ///         the flash-cycle defense lives on the new LP position, not on this internal hand-off (§5.3).
    /// @dev    ATO-only move: it transfers custodial ATO out and adjusts the stake ledger. It NEVER touches
    ///         reserve/feesAccrued/rewardPool, so the ETH partition invariant is untouched, and it mints/
    ///         burns nothing, so `ATO.totalSupply()` and curve solvency are unaffected. CEI: ledger effects
    ///         precede the transfer; `nonReentrant` for defense in depth.
    function unstakeFor(address user, uint256 amount, address to) external nonReentrant {
        _updateReward(user);
        if (msg.sender != lpManager) revert NotLPManager();
        if (amount == 0) revert ZeroAmount();
        if (amount > tier1Staked[user]) revert ExceedsStake();

        tier1Staked[user] -= amount;
        weight[user] -= amount;
        totalWeight -= amount;
        if (totalWeight == 0) _bankRemainder(); // sole staker emptied the book: freeze + park remainder

        SafeTransferLib.safeTransfer(address(ato), to, amount); // hand the custodial ATO to the LP manager
        emit UnstakedFor(user, amount, to);
    }

    /// @notice Atomically RE-STAKE `amount` ATO into `user`'s tier-1 custodial stake, pulled from the caller
    ///         (the LP manager) via transferFrom. The counterpart to `unstakeFor`: `depositFromStake` uses it
    ///         to return the UNUSED slice of stake-sourced ATO to STAKE (preserving the 6-block hold) instead
    ///         of leaking it hold-free to the wallet. onlyLPManager; the manager passes
    ///         `msg.sender` as `user`, so a caller can only ever restake into their OWN stake. Mirrors
    ///         `stake`'s effects (settle rewards, bump tier1Staked/weight/totalWeight, arm a FRESH 6-block
    ///         hold, flush the no-staker buffer if it bootstraps the book).
    /// @dev    ATO-only move: never touches reserve/feesAccrued/rewardPool, so the ETH partition is untouched;
    ///         no mint/burn, so curve solvency and `totalSupply == totalMinted + atoClaims` are unaffected.
    function stakeFor(address user, uint256 amount) external nonReentrant {
        if (msg.sender != lpManager) revert NotLPManager();
        if (amount == 0) revert ZeroAmount();
        _updateReward(user);
        bool wasEmpty = totalWeight == 0;

        tier1Staked[user] += amount;
        weight[user] += amount;
        totalWeight += amount;
        depositBlock[user] = block.number; // arm a fresh hold on the returned stake

        SafeTransferLib.safeTransferFrom(address(ato), msg.sender, address(this), amount);
        if (wasEmpty) _flushBufferIfAny();
        emit Staked(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev ETH inflow. TWO sources, handled differently:
    ///      (1) the manager's `take(ETH)` on every BUY — `msg.sender == poolManager`. This ETH is ALREADY
    ///          accounted by `_processBuy` into `reserve`/`feesAccrued`, so it must NOT be folded (doing so
    ///          would double-count the buy as a reward and break solvency). Skipped via the sender guard.
    ///      (2) a raw DONATION from anyone else — folded straight into the reward stream ON ARRIVAL (INFO-2),
    ///          so it is credited to stakers immediately (no second tx) and the DERIVED `rewardPool()`
    ///          residual stays consistent with the Synthetix accumulator. The `msg.value != 0` guard makes a
    ///          0-value empty-calldata call a no-op so it can't reset the 7-day stream window.
    ///      NB: ETH force-sent via `selfdestruct` or to the pre-deploy address does NOT invoke `receive`, so
    ///      it isn't auto-credited — a rare, benign over-collateralization (it only ever raises `rewardPool()`).
    receive() external payable {
        if (msg.value != 0 && msg.sender != address(poolManager)) {
            _foldIntoStream(msg.value);
            emit RewardDonated(msg.sender, msg.value);
        }
    }

    /// @dev Burn the prior parked backlog — real ATO that earlier sellers already settled, so it is
    ///      physically in the manager and the `take` needs no float (the deferred sato-style burn).
    ///      Capped at the manager's live ATO balance so a same-tx batch of sells (whose claims aren't
    ///      settled yet) can never make `take` revert — it just defers a sliver to the next sell.
    ///      Delta-neutral on the swap (`burn` +b, `take` -b); `ato.burn` then reduces real supply.
    function _burnBacklog(uint256 backlog) private {
        if (backlog == 0) return;
        uint256 present = ato.balanceOf(address(poolManager));
        uint256 b = backlog < present ? backlog : present;
        if (b == 0) return;
        poolManager.burn(address(this), ATO_ID, b); // release the claim (+b ATO delta)
        poolManager.take(atoCurrency, address(this), b); // pull the real ATO to the hook (-b ATO delta)
        ato.burn(address(this), b); // destroy supply — totalSupply ↓
        atoClaims -= b;
    }

    function _enforceHold(address account) internal view {
        if (block.number < depositBlock[account] + HOLD_BLOCKS) revert HoldNotElapsed();
    }

    /// @dev Checked uint256 → int128 (v4 deltas are int128). Reverts on truncation.
    function _toI128(uint256 x) private pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert AmountOverflow();
        return int128(int256(x));
    }
}
