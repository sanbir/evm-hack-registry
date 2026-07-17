// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LootToken} from "./LootToken.sol";

/// @title HeisenbergHook
/// @notice The Dr. Heisenberg Uniswap V4 hook. Implements the windowed-heist mechanic, the 2% input-side
///         fee with a 50/40/10 split (treasury / platform / buy-and-burn), the post-launch buy cap, and
///         the LP-locking restrictions on the $HEIST/ETH pool.
/// @dev    All ETH-quoted accounting in this contract is denominated in wei. The pool is expected to be
///         (currency0 = native ETH, currency1 = $HEIST). The hook validates this on initialize.
contract HeisenbergHook is BaseHook {
    using CurrencySettler for Currency;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Window length of a single heist, in blocks (~30 minutes on Ethereum mainnet).
    uint256 public constant HEIST_WINDOW_BLOCKS = 300;
    /// @notice Initial buy cap at launch, in basis points of total supply. 250 = 2.5%.
    uint256 public constant BUY_CAP_INITIAL_BP = 250;
    /// @notice Per-block ramp added to the buy cap, in basis points. 100 = +1% per block.
    uint256 public constant BUY_CAP_RAMP_PER_BLOCK_BP = 100;
    /// @notice Buy-cap ceiling in basis points. 10_000 = 100% (cap effectively removed).
    uint256 public constant BUY_CAP_MAX_BP = 10_000;
    /// @notice Per-block heat decay, scaled to 1e18. 0.9999 per block.
    uint256 public constant HEAT_DECAY_RATE = 0.9999e18;
    /// @notice Score scaling constant; tunes overall $LOOT issuance.
    uint256 public constant SCORE_CONSTANT = 1e18;
    /// @notice Divisor controlling bust sensitivity to average heat.
    uint256 public constant HEAT_BUST_DIVISOR = 1000e18;
    /// @notice Hook fee in basis points (200 = 2%).
    uint16 public constant HOOK_FEE_BP = 200;
    /// @notice Fee split: 50% treasury, 40% platform, 10% buy-and-burn (in basis points).
    uint16 public constant FEE_TO_TREASURY_BP = 5000;
    uint16 public constant FEE_TO_PLATFORM_BP = 4000;
    uint16 public constant FEE_TO_BURN_BP = 1000;
    /// @notice Era halving multiplier base. Era 0 = 1.0e18, era N = 1e18 / 2**N.
    uint256 public constant ERA0_MULTIPLIER = 1e18;
    /// @notice Cumulative buy volume (ETH) required to trigger era 1 (and base for subsequent doublings).
    uint256 public constant ERA1_THRESHOLD_ETH = 100 ether;
    /// @notice Dead address used for $HEIST burns.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Length of the circular swap buffer used for coherence sampling.
    uint256 public constant COHERENCE_BUFFER_LEN = 32;

    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The $HEIST ERC-20 token.
    IERC20 public immutable HEIST;
    /// @notice The $LOOT ERC-20 token.
    LootToken public immutable LOOT;
    /// @notice Receives 40% of all hook fees.
    address public immutable platformWallet;
    /// @notice Total supply of $HEIST (cached for buy-cap math).
    uint256 public immutable heistTotalSupply;
    /// @notice Block at which the hook was deployed; used for buy-cap ramp.
    uint256 public immutable launchBlock;

    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The PoolKey of the configured $HEIST/ETH pool. Set on first beforeInitialize.
    PoolKey public poolKey;
    /// @notice True once `poolKey` has been set.
    bool public poolInitialized;

    /// @notice Current heist id; increments each time a window resolves.
    uint256 public currentHeistId;
    /// @notice Block at which the current heist began.
    uint256 public heistStartBlock;
    /// @notice Global heat accumulator (1e18-scaled). Decays per block.
    uint256 public globalHeat;
    /// @notice Last block at which `globalHeat` was lazy-decayed.
    uint256 public lastHeatUpdateBlock;
    /// @notice Bitcoin-style halving epoch.
    uint256 public currentEra;
    /// @notice All-time cumulative buy volume in ETH (wei). Used for era halvings.
    uint256 public cumulativeBuyVolumeETH;
    /// @notice $LOOT accumulated from busted heists; paid out on next clean heist.
    uint256 public lockupFund;
    /// @notice ETH (wei) earmarked as the redemption-backing treasury.
    uint256 public heistTreasuryETH;
    /// @notice ETH (wei) earmarked for the next $HEIST buy-and-burn cycle.
    uint256 public pendingBurnETH;
    /// @notice $HEIST (wei) sitting in the hook from sell-side fees, awaiting conversion via `processFees`.
    uint256 public pendingFeeHEIST;
    /// @notice Cumulative $HEIST burned by the hook (transparency counter).
    uint256 public cumulativeBurnedHEIST;

    /// @notice Circular buffer of recent signed swap volumes (positive = buy, negative = sell), in ETH wei.
    int256[COHERENCE_BUFFER_LEN] public swapBuffer;
    /// @notice Next write index for `swapBuffer`.
    uint8 public swapBufferIndex;

    /// @notice Per-heist crew membership lists.
    mapping(uint256 => address[]) internal _crewMembers;
    /// @notice Per-heist crew contributions (in ETH wei).
    mapping(uint256 => mapping(address => uint256)) public crewContribution;
    /// @notice Per-heist crew timing tier (0 = earliest, 3 = latest).
    mapping(uint256 => mapping(address => uint8)) public crewTimingTier;
    /// @notice Whether a given address has joined a given heist (used to dedupe push to the array).
    mapping(uint256 => mapping(address => bool)) public crewJoined;
    /// @notice Sum of buy volume (ETH wei) for a heist.
    mapping(uint256 => uint256) public heistBuyVolumeETH;
    /// @notice Time-weighted average heat for a heist (1e18-scaled).
    mapping(uint256 => uint256) public heistAvgHeat;
    /// @notice Internal accumulator for heat-time integration; divided by elapsed blocks at resolve.
    mapping(uint256 => uint256) public heistHeatTimeIntegral;
    /// @notice Last block at which the heat integral for a heist was advanced.
    mapping(uint256 => uint256) public heistLastIntegralBlock;
    /// @notice Whether a given heist has been resolved.
    mapping(uint256 => bool) public heistResolved;
    /// @notice Stored outcome of a resolved heist.
    mapping(uint256 => HeistOutcome) public heistOutcome;

    /// @notice Timing-tier multipliers (1e18-scaled). [first-25%, second-25%, third-25%, last-25%].
    uint256[4] public timingMultiplier = [uint256(1.5e18), 1.2e18, 1.0e18, 0.7e18];

    /// @notice Stored outcome shape for completed heists.
    /// @param resolved True once the heist has been resolved.
    /// @param busted True if the heist was busted.
    /// @param totalScore The final score after bust/lockup adjustments (1e18-scaled).
    /// @param lockupBonus The bonus drawn from `lockupFund` for a clean heist (or 0 on bust).
    /// @param finalLootMinted Total $LOOT minted to the crew (in wei).
    /// @param crewSize Number of unique crew members.
    /// @param avgHeat Time-weighted average heat over the window (1e18-scaled).
    /// @param coherence Coherence value for the heist (1e18-scaled).
    /// @param resolvedAtBlock Block at which the heist was resolved.
    struct HeistOutcome {
        bool resolved;
        bool busted;
        uint256 totalScore;
        uint256 lockupBonus;
        uint256 finalLootMinted;
        uint256 crewSize;
        uint256 avgHeat;
        uint256 coherence;
        uint256 resolvedAtBlock;
    }

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a buy-side crew member joins a heist for the first time.
    /// @param heistId The heist they joined.
    /// @param member Crew member.
    /// @param tier Timing tier captured at first buy.
    event CrewJoined(uint256 indexed heistId, address indexed member, uint8 tier);

    /// @notice Emitted whenever a crew member's contribution increments.
    /// @param heistId Heist id.
    /// @param member Crew member.
    /// @param ethAmount ETH (wei) added to their contribution.
    event CrewContribution(uint256 indexed heistId, address indexed member, uint256 ethAmount);

    /// @notice Emitted when a heist resolves.
    /// @param heistId Heist id.
    /// @param busted True if busted, false if clean.
    /// @param totalScore Final score.
    /// @param lockupBonus Lockup bonus applied (0 if busted).
    /// @param finalLootMinted Total $LOOT minted to the crew.
    /// @param avgHeat Time-weighted average heat over the window.
    /// @param coherence Coherence value.
    event HeistResolved(
        uint256 indexed heistId,
        bool busted,
        uint256 totalScore,
        uint256 lockupBonus,
        uint256 finalLootMinted,
        uint256 avgHeat,
        uint256 coherence
    );

    /// @notice Emitted when an era halving fires.
    /// @param newEra Era id after the halving.
    /// @param atCumulativeETH Cumulative ETH buy volume at the time of halving.
    event EraAdvanced(uint256 indexed newEra, uint256 atCumulativeETH);

    /// @notice Emitted when ETH-side fees are split.
    /// @param toTreasury ETH added to treasury.
    /// @param toPlatform ETH sent to platform wallet.
    /// @param toBurn ETH added to pending buy-and-burn pool.
    event FeesSplit(uint256 toTreasury, uint256 toPlatform, uint256 toBurn);

    /// @notice Emitted when the pool key is captured on first initialize.
    event PoolKeySet(PoolId indexed poolId);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when an unsupported pool tries to use this hook (must be ETH/HEIST).
    error PoolNotSupported();
    /// @notice Reverts when LP add/remove is attempted post-launch.
    error LiquidityLocked();
    /// @notice Reverts when a buy exceeds the current ramped buy cap.
    error BuyCapExceeded();
    /// @notice Reverts when a non-Loot caller tries to call `payRedemption`.
    error OnlyLoot();
    /// @notice Reverts when treasury cannot cover a payout.
    error InsufficientTreasury();
    /// @notice Reverts when ETH transfer fails.
    error EthTransferFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the hook and wires it to the tokens and platform wallet.
    /// @param _poolManager The Uniswap V4 PoolManager.
    /// @param _heist The $HEIST ERC-20.
    /// @param _loot The $LOOT ERC-20 (its `setHook` will be called separately by the deployer).
    /// @param _platformWallet Recipient of 40% of all fees.
    /// @param _heistTotalSupply Total supply of $HEIST in wei (used for buy-cap math).
    constructor(
        IPoolManager _poolManager,
        IERC20 _heist,
        LootToken _loot,
        address _platformWallet,
        uint256 _heistTotalSupply
    ) BaseHook(_poolManager) {
        HEIST = _heist;
        LOOT = _loot;
        platformWallet = _platformWallet;
        heistTotalSupply = _heistTotalSupply;
        launchBlock = block.number;
        heistStartBlock = block.number;
        lastHeatUpdateBlock = block.number;
        heistLastIntegralBlock[0] = block.number;
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                            HOOK CALLBACK BODIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Captures the pool key and validates it is the ETH/HEIST pair.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Currency0 must be native ETH; currency1 must be $HEIST.
        if (Currency.unwrap(key.currency0) != address(0)) revert PoolNotSupported();
        if (Currency.unwrap(key.currency1) != address(HEIST)) revert PoolNotSupported();
        poolKey = key;
        poolInitialized = true;
        emit PoolKeySet(key.toId());
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev LP add/remove permissioning is handled OFF-HOOK by who holds the LP NFT. The deployer
    /// @dev keeps the position NFT to manage liquidity, and "locks" the LP simply by burning the NFT
    /// @dev to a dead address (or sending it to a timelock). The hook does not gate add/remove —
    /// @dev that would block the deployer's legitimate post-launch LP management.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @dev Window check, buy-cap enforcement, heat decay, fee delta setup.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _decayGlobalHeat();
        _maybeResolveAndAdvance();

        bool isBuy = params.zeroForOne; // ETH -> HEIST
        bool isExactInput = params.amountSpecified < 0;

        // Determine input amount in the input currency. Unsupported swap shapes (exact-output) skip fee.
        uint256 inputAmount;
        if (isExactInput) {
            inputAmount = uint256(-params.amountSpecified);
        } else {
            // Exact-output swaps are allowed but fee math is skipped to keep accounting unambiguous.
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Enforce buy cap on buys (input is ETH, but cap is denominated in $HEIST output tokens; we
        // approximate by capping the ETH input proportionally to current pool price using a
        // conservative rule: cap = pct * totalSupply, and we forbid ETH-input that exceeds
        // cap * 1 ETH / 1 HEIST as an upper bound. In practice the cap reaches 100% within ~98 blocks
        // so this approximation only matters for the launch window.).
        if (isBuy) {
            uint256 capBp = getCurrentBuyCapBp();
            uint256 maxHeistOut = (heistTotalSupply * capBp) / BUY_CAP_MAX_BP;
            // Conservative pre-trade check: ensure the requested ETH input would not buy more than
            // `maxHeistOut` at a 1:1 price floor. Real price quotes are not available pre-swap.
            if (inputAmount > maxHeistOut) revert BuyCapExceeded();
        }

        // Compute fee on input.
        uint256 feeAmount = (inputAmount * HOOK_FEE_BP) / 10_000;
        if (feeAmount == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // Take the fee from the manager into the hook in the input currency.
        Currency inputCurrency = isBuy ? key.currency0 : key.currency1;
        inputCurrency.take(poolManager, address(this), feeAmount, false);

        // Return a delta that reduces the swap's input by the fee amount.
        // For exact-input, amountSpecified is negative; specifiedDelta positive offsets it.
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(feeAmount)), 0);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    /// @dev Heat update, fee splitting / accumulation, crew-membership recording, coherence sampling.
    /// @dev If `hookData` contains a 32-byte abi-encoded address, that address is credited as the crew
    /// @dev member. This lets routers (UniversalRouter / custom) forward the real EOA. If hookData is
    /// @dev empty or malformed, falls back to `sender`, which is the address that called the
    /// @dev PoolManager — fine for direct swaps, but for routed swaps it will be the router itself.
    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        address crewMember = sender;
        if (hookData.length == 32) {
            address forwarded = abi.decode(hookData, (address));
            if (forwarded != address(0)) crewMember = forwarded;
        }
        bool isBuy = params.zeroForOne;
        // ETH-equivalent size of this swap: the absolute amount of currency0 (ETH) moved.
        // delta.amount0() is from the caller's perspective.
        int128 amt0 = delta.amount0();
        uint256 ethSize = uint256(int256(amt0 < 0 ? -amt0 : amt0));

        // Update global heat.
        if (isBuy) {
            globalHeat += ethSize * 1e18;
        } else {
            globalHeat += (ethSize * 1e18) / 2;
        }

        // Update cumulative buy volume + era halvings.
        if (isBuy) {
            cumulativeBuyVolumeETH += ethSize;
            _maybeAdvanceEra();
        }

        // Push signed volume into circular buffer (positive on buy, negative on sell).
        int256 signedVol = int256(ethSize);
        if (!isBuy) signedVol = -signedVol;
        swapBuffer[swapBufferIndex] = signedVol;
        swapBufferIndex = uint8((uint256(swapBufferIndex) + 1) % COHERENCE_BUFFER_LEN);

        // Sample heat into the heist's heat-time integral.
        _sampleHeistHeat(currentHeistId);

        // Record crew membership on buys (using forwarded EOA from hookData if provided).
        if (isBuy && ethSize > 0) {
            uint256 hid = currentHeistId;
            if (!crewJoined[hid][crewMember]) {
                crewJoined[hid][crewMember] = true;
                _crewMembers[hid].push(crewMember);
                uint256 elapsed = block.number - heistStartBlock;
                uint8 tier = uint8((elapsed * 4) / HEIST_WINDOW_BLOCKS);
                if (tier > 3) tier = 3;
                crewTimingTier[hid][crewMember] = tier;
                emit CrewJoined(hid, crewMember, tier);
            }
            crewContribution[hid][crewMember] += ethSize;
            heistBuyVolumeETH[hid] += ethSize;
            emit CrewContribution(hid, crewMember, ethSize);
        }

        // Split / accumulate the fee taken in beforeSwap.
        if (isBuy) {
            // Fee is held by the hook as ETH (currency0 is native; take settled it as actual ETH).
            uint256 feeAmount = (ethSize * HOOK_FEE_BP) / 10_000;
            // ethSize already excludes the fee since the swap was reduced; we must compute the original
            // input. delta.amount0() shows the post-fee input to the pool, so we add fee back.
            uint256 originalInput = ethSize + feeAmount;
            feeAmount = (originalInput * HOOK_FEE_BP) / 10_000;
            _splitEthFee(feeAmount);
        } else {
            // Fee was taken in HEIST and sits in this contract; accumulate for processFees().
            uint256 outAmount = uint256(int256(amt0 < 0 ? -amt0 : amt0));
            // For a sell, input is HEIST. We need to reconstruct it from delta.amount1().
            int128 amt1 = delta.amount1();
            uint256 heistIn = uint256(int256(amt1 < 0 ? -amt1 : amt1));
            uint256 feeHeist = ((heistIn + (heistIn * HOOK_FEE_BP) / 10_000) * HOOK_FEE_BP) / 10_000;
            // Simpler: recompute from the original spec amount, since fee = inputBeforeFee * 0.02 / 1.
            // We track exactly what take() pulled in beforeSwap by recomputing here via the delta.
            // For accuracy: feeHeist = (heistIn * HOOK_FEE_BP) / (10_000 - HOOK_FEE_BP).
            feeHeist = (heistIn * HOOK_FEE_BP) / (10_000 - HOOK_FEE_BP);
            pendingFeeHEIST += feeHeist;
            outAmount; // silence unused-var warning (kept for readability of the delta.amount0 line above)
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: STATE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Lazy-decays the global heat across the elapsed blocks.
    function _decayGlobalHeat() internal {
        uint256 elapsed = block.number - lastHeatUpdateBlock;
        if (elapsed == 0 || globalHeat == 0) {
            lastHeatUpdateBlock = block.number;
            return;
        }
        // Cap iterations to prevent griefing. After ~10000 blocks heat is essentially zero anyway.
        if (elapsed > 10_000) elapsed = 10_000;
        uint256 factor = _powDecay(elapsed);
        globalHeat = (globalHeat * factor) / 1e18;
        lastHeatUpdateBlock = block.number;
    }

    /// @dev Samples current heat into the running integral for the given heist.
    function _sampleHeistHeat(uint256 hid) internal {
        uint256 last = heistLastIntegralBlock[hid];
        if (last == 0) last = heistStartBlock;
        uint256 dt = block.number - last;
        if (dt > 0) {
            heistHeatTimeIntegral[hid] += globalHeat * dt;
            heistLastIntegralBlock[hid] = block.number;
        }
    }

    /// @dev If the current window has expired, resolve it and start the next one.
    function _maybeResolveAndAdvance() internal {
        if (block.number >= heistStartBlock + HEIST_WINDOW_BLOCKS && !heistResolved[currentHeistId]) {
            _resolveHeist(currentHeistId);
            currentHeistId += 1;
            heistStartBlock = block.number;
            heistLastIntegralBlock[currentHeistId] = block.number;
        }
    }

    /// @dev Resolves a heist: computes score, rolls bust, distributes $LOOT.
    function _resolveHeist(uint256 hid) internal {
        if (heistResolved[hid]) return;
        // Finalize average heat.
        _sampleHeistHeat(hid);
        uint256 windowBlocks = block.number - heistStartBlock;
        uint256 avgHeat = windowBlocks == 0 ? globalHeat : heistHeatTimeIntegral[hid] / windowBlocks;
        heistAvgHeat[hid] = avgHeat;

        uint256 buyVol = heistBuyVolumeETH[hid];
        uint256 score = (buyVol * _sqrt(avgHeat / 1e9) * eraMultiplier()) / 1e18;
        score = (score * SCORE_CONSTANT) / 1e18;

        uint256 coherence = _computeCoherence();
        // Coherence is in [0.2e18, 2e18]. Above 1e18 means a same-sign streak (no bust risk).
        // Below 1e18 means opposing-trade noise that increases bust risk. Clamp to avoid underflow.
        uint256 incoherence = coherence < 1e18 ? 1e18 - coherence : 0;
        uint256 bustChance = (avgHeat * incoherence) / HEAT_BUST_DIVISOR;
        if (bustChance > 1e18) bustChance = 1e18;

        uint256 randWord = uint256(keccak256(abi.encodePacked(block.prevrandao, hid)));
        bool busted = (randWord % 1e18) < bustChance;

        uint256 lockupBonus = 0;
        if (busted) {
            uint256 forfeit = score / 2;
            score = score - forfeit;
            lockupFund += forfeit;
            globalHeat = 0;
        } else {
            lockupBonus = lockupFund;
            score += lockupBonus;
            lockupFund = 0;
        }

        // Distribute $LOOT to crew.
        uint256 totalMinted = 0;
        if (buyVol > 0 && score > 0) {
            address[] storage crew = _crewMembers[hid];
            // Compute weighted contribution sum.
            uint256 weightedSum = 0;
            for (uint256 i = 0; i < crew.length; i++) {
                address m = crew[i];
                uint8 tier = crewTimingTier[hid][m];
                weightedSum += (crewContribution[hid][m] * timingMultiplier[tier]) / 1e18;
            }
            if (weightedSum > 0) {
                for (uint256 i = 0; i < crew.length; i++) {
                    address m = crew[i];
                    uint8 tier = crewTimingTier[hid][m];
                    uint256 w = (crewContribution[hid][m] * timingMultiplier[tier]) / 1e18;
                    uint256 share = (score * w) / weightedSum;
                    if (share > 0) {
                        LOOT.mintToHolder(m, share);
                        totalMinted += share;
                    }
                }
            }
        }

        heistOutcome[hid] = HeistOutcome({
            resolved: true,
            busted: busted,
            totalScore: score,
            lockupBonus: lockupBonus,
            finalLootMinted: totalMinted,
            crewSize: _crewMembers[hid].length,
            avgHeat: avgHeat,
            coherence: coherence,
            resolvedAtBlock: block.number
        });
        heistResolved[hid] = true;

        emit HeistResolved(hid, busted, score, lockupBonus, totalMinted, avgHeat, coherence);
    }

    /// @dev Era halving check.
    function _maybeAdvanceEra() internal {
        uint256 threshold = nextEraThreshold();
        if (cumulativeBuyVolumeETH >= threshold) {
            currentEra += 1;
            emit EraAdvanced(currentEra, cumulativeBuyVolumeETH);
        }
    }

    /// @dev Splits an ETH-denominated fee into 50/40/10 (treasury/platform/burn) and routes platform share.
    function _splitEthFee(uint256 feeAmount) internal {
        if (feeAmount == 0) return;
        uint256 toTreasury = (feeAmount * FEE_TO_TREASURY_BP) / 10_000;
        uint256 toPlatform = (feeAmount * FEE_TO_PLATFORM_BP) / 10_000;
        uint256 toBurn = feeAmount - toTreasury - toPlatform;
        heistTreasuryETH += toTreasury;
        pendingBurnETH += toBurn;
        (bool ok,) = platformWallet.call{value: toPlatform}("");
        if (!ok) revert EthTransferFailed();
        emit FeesSplit(toTreasury, toPlatform, toBurn);
    }

    /*//////////////////////////////////////////////////////////////
                                  MATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Era multiplier (1e18-scaled). Era 0 = 1.0, halves each subsequent era.
    /// @return mul The current era multiplier.
    function eraMultiplier() public view returns (uint256 mul) {
        mul = ERA0_MULTIPLIER >> currentEra;
    }

    /// @notice Cumulative ETH buy-volume threshold required to trigger the next era halving.
    /// @return threshold ETH (wei) required.
    function nextEraThreshold() public view returns (uint256 threshold) {
        // Era 1 at 100 ETH, era 2 at 100 + 200 = 300 ETH, era 3 at 300 + 400 = 700 ETH, etc.
        // i.e. threshold for era N = 100 * (2^N - 1).
        threshold = ERA1_THRESHOLD_ETH * ((1 << (currentEra + 1)) - 1);
    }

    /// @notice Current buy cap in basis points of total $HEIST supply.
    /// @return capBp The cap in bp.
    function getCurrentBuyCapBp() public view returns (uint256 capBp) {
        uint256 elapsed = block.number - launchBlock;
        capBp = BUY_CAP_INITIAL_BP + (elapsed * BUY_CAP_RAMP_PER_BLOCK_BP);
        if (capBp > BUY_CAP_MAX_BP) capBp = BUY_CAP_MAX_BP;
    }

    /// @notice Maximum single buy in $HEIST tokens (wei) given the current cap.
    /// @return cap Tokens.
    function getCurrentBuyCap() external view returns (uint256 cap) {
        cap = (heistTotalSupply * getCurrentBuyCapBp()) / BUY_CAP_MAX_BP;
    }

    /// @dev Computes (HEAT_DECAY_RATE / 1e18) ** n in 1e18 fixed-point via fast exponentiation.
    function _powDecay(uint256 n) internal pure returns (uint256 result) {
        result = 1e18;
        uint256 base = HEAT_DECAY_RATE;
        while (n > 0) {
            if (n & 1 == 1) result = (result * base) / 1e18;
            base = (base * base) / 1e18;
            n >>= 1;
        }
    }

    /// @dev Babylonian sqrt.
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Coherence in [0.2e18, 2.0e18] from the circular swap buffer.
    /// @dev Implementation: Gaussian-weighted alignment of consecutive same-sign swaps.
    function _computeCoherence() internal view returns (uint256) {
        int256 alignSum = 0;
        uint256 weightSum = 0;
        // Center weight at the buffer's middle index.
        int256 center = int256(COHERENCE_BUFFER_LEN / 2);
        for (uint256 i = 1; i < COHERENCE_BUFFER_LEN; i++) {
            int256 a = swapBuffer[i - 1];
            int256 b = swapBuffer[i];
            if (a == 0 || b == 0) continue;
            // Gaussian-ish weight (1e18 / (1 + (i - center)^2)).
            int256 d = int256(i) - center;
            uint256 w = 1e18 / uint256(1 + uint256(d * d));
            weightSum += w;
            // Same sign +w, opposite sign -w.
            bool sameSign = (a > 0) == (b > 0);
            if (sameSign) alignSum += int256(w);
            else alignSum -= int256(w);
        }
        if (weightSum == 0) return 1e18; // Neutral if buffer is empty.
        // Normalize alignSum to [-1e18, 1e18] then map to [0.2e18, 2.0e18].
        int256 norm = (alignSum * 1e18) / int256(weightSum);
        // Map: -1e18 -> 0.2e18, +1e18 -> 2.0e18, linear.
        int256 mapped = int256(0.2e18) + ((norm + 1e18) * (2e18 - 0.2e18)) / (2 * 1e18);
        if (mapped < int256(0.2e18)) mapped = int256(0.2e18);
        if (mapped > int256(2e18)) mapped = int256(2e18);
        return uint256(mapped);
    }

    /*//////////////////////////////////////////////////////////////
                              FEE PROCESSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts pending HEIST-denominated fees to ETH and re-splits them. Anyone can call.
    /// @dev    Performs an internal swap on the configured pool. Skips silently if there are no fees pending.
    function processFees() external {
        if (pendingFeeHEIST == 0 || !poolInitialized) return;
        uint256 amount = pendingFeeHEIST;
        pendingFeeHEIST = 0;

        // Approve manager via unlock callback to swap HEIST -> ETH.
        bytes memory data = abi.encode(uint256(1), amount); // op = 1 (HEIST->ETH)
        bytes memory result = poolManager.unlock(data);
        uint256 ethReceived = abi.decode(result, (uint256));
        _splitEthFee(ethReceived);
    }

    /// @notice Burns pending ETH-earmarked fees by swapping ETH→HEIST and sending to the dead address.
    /// @dev    Anyone can call. Skips silently if there are no fees pending.
    function processBurn() external {
        if (pendingBurnETH == 0 || !poolInitialized) return;
        uint256 amount = pendingBurnETH;
        pendingBurnETH = 0;

        bytes memory data = abi.encode(uint256(2), amount); // op = 2 (ETH->HEIST then burn)
        bytes memory result = poolManager.unlock(data);
        uint256 heistReceived = abi.decode(result, (uint256));
        cumulativeBurnedHEIST += heistReceived;
        if (heistReceived > 0) IERC20(address(HEIST)).transfer(DEAD, heistReceived);
    }

    /// @notice PoolManager unlock callback for internal fee-processing swaps.
    /// @param data Encoded (op, amount). op==1 swaps HEIST->ETH; op==2 swaps ETH->HEIST.
    /// @return Encoded uint256 result amount.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 op, uint256 amount) = abi.decode(data, (uint256, uint256));

        if (op == 1) {
            // Sell HEIST for ETH (zeroForOne = false).
            BalanceDelta delta = poolManager.swap(
                poolKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            // Settle HEIST in.
            poolKey.currency1.settle(poolManager, address(this), amount, false);
            // Take ETH out.
            uint256 ethOut = uint256(int256(delta.amount0()));
            poolKey.currency0.take(poolManager, address(this), ethOut, false);
            return abi.encode(ethOut);
        } else if (op == 2) {
            // Buy HEIST with ETH (zeroForOne = true).
            BalanceDelta delta = poolManager.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            poolKey.currency0.settle(poolManager, address(this), amount, false);
            uint256 heistOut = uint256(int256(delta.amount1()));
            poolKey.currency1.take(poolManager, address(this), heistOut, false);
            return abi.encode(heistOut);
        }
        return abi.encode(uint256(0));
    }

    /*//////////////////////////////////////////////////////////////
                            REDEMPTION TREASURY
    //////////////////////////////////////////////////////////////*/

    /// @notice Pays an ETH redemption to a $LOOT redeemer. Only callable by the configured Loot token.
    /// @param to Recipient.
    /// @param ethAmount ETH (wei) to release.
    function payRedemption(address to, uint256 ethAmount) external {
        if (msg.sender != address(LOOT)) revert OnlyLoot();
        if (ethAmount > heistTreasuryETH) revert InsufficientTreasury();
        heistTreasuryETH -= ethAmount;
        (bool ok,) = to.call{value: ethAmount}("");
        if (!ok) revert EthTransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice High-level snapshot of the current heist for a frontend.
    /// @return heistId Current heist id.
    /// @return startBlock Block at which the current heist began.
    /// @return blocksRemaining Blocks left in the current window (0 if expired).
    /// @return crewSize Unique crew member count for the current heist.
    /// @return totalBuyVolumeETH Total buy volume (wei) in the current heist so far.
    /// @return currentScoreEstimate A live score estimate using current heat.
    /// @return currentHeat Current global heat (1e18-scaled).
    /// @return currentCoherence Current coherence (1e18-scaled).
    /// @return currentBustRisk Current bust probability (1e18-scaled).
    function getCurrentHeistInfo()
        external
        view
        returns (
            uint256 heistId,
            uint256 startBlock,
            uint256 blocksRemaining,
            uint256 crewSize,
            uint256 totalBuyVolumeETH,
            uint256 currentScoreEstimate,
            uint256 currentHeat,
            uint256 currentCoherence,
            uint256 currentBustRisk
        )
    {
        heistId = currentHeistId;
        startBlock = heistStartBlock;
        uint256 endBlock = heistStartBlock + HEIST_WINDOW_BLOCKS;
        blocksRemaining = block.number >= endBlock ? 0 : endBlock - block.number;
        crewSize = _crewMembers[currentHeistId].length;
        totalBuyVolumeETH = heistBuyVolumeETH[currentHeistId];

        currentHeat = _peekDecayedHeat();
        currentCoherence = _computeCoherence();
        currentScoreEstimate =
            (totalBuyVolumeETH * _sqrt(currentHeat / 1e9) * eraMultiplier()) / 1e18 * SCORE_CONSTANT / 1e18;
        uint256 incoherence = currentCoherence < 1e18 ? 1e18 - currentCoherence : 0;
        uint256 risk = (currentHeat * incoherence) / HEAT_BUST_DIVISOR;
        currentBustRisk = risk > 1e18 ? 1e18 : risk;
    }

    /// @notice Returns the contribution, timing tier, and an estimated payout for a crew member.
    /// @param hid Heist id.
    /// @param member Crew member.
    /// @return contribution ETH (wei) the member contributed in that heist.
    /// @return tier Their timing tier (0..3).
    /// @return estimatedPayout Approximate $LOOT they'd receive at current state.
    function getCrewMember(uint256 hid, address member)
        external
        view
        returns (uint256 contribution, uint8 tier, uint256 estimatedPayout)
    {
        contribution = crewContribution[hid][member];
        tier = crewTimingTier[hid][member];
        if (heistResolved[hid]) {
            // Approximate from outcome.
            HeistOutcome storage o = heistOutcome[hid];
            uint256 totalVol = heistBuyVolumeETH[hid];
            if (totalVol > 0 && o.totalScore > 0) {
                estimatedPayout =
                    (o.totalScore * (contribution * timingMultiplier[tier] / 1e18)) / _weightedSum(hid);
            }
        }
    }

    /// @dev Helper used by previewHeistEntry / getCrewMember.
    function _weightedSum(uint256 hid) internal view returns (uint256 s) {
        address[] storage crew = _crewMembers[hid];
        for (uint256 i = 0; i < crew.length; i++) {
            address m = crew[i];
            uint8 tier = crewTimingTier[hid][m];
            s += (crewContribution[hid][m] * timingMultiplier[tier]) / 1e18;
        }
    }

    /// @notice Returns the number of crew members in a heist.
    /// @param hid Heist id.
    /// @return count Crew member count.
    function getCrewMemberCount(uint256 hid) external view returns (uint256 count) {
        count = _crewMembers[hid].length;
    }

    /// @notice Returns the address of a specific crew member by index.
    /// @param hid Heist id.
    /// @param index Index in the crew list.
    /// @return member Crew member address.
    function getCrewMemberAt(uint256 hid, uint256 index) external view returns (address member) {
        member = _crewMembers[hid][index];
    }

    /// @notice Returns the stored outcome for a resolved heist.
    /// @param hid Heist id.
    /// @return resolved Whether it has been resolved.
    /// @return busted Whether it was busted.
    /// @return totalScore Final score.
    /// @return lockupBonus Lockup bonus applied.
    /// @return finalLootMinted Total $LOOT minted.
    function getHeistOutcome(uint256 hid)
        external
        view
        returns (bool resolved, bool busted, uint256 totalScore, uint256 lockupBonus, uint256 finalLootMinted)
    {
        HeistOutcome storage o = heistOutcome[hid];
        return (o.resolved, o.busted, o.totalScore, o.lockupBonus, o.finalLootMinted);
    }

    /// @notice Snapshot of global protocol state.
    /// @return currentHeat Decayed global heat.
    /// @return era Current era.
    /// @return eraMul Era multiplier.
    /// @return cumBuyEth Cumulative buy volume in ETH wei.
    /// @return lockup Current lockup fund (in $LOOT wei).
    /// @return treasury Current ETH treasury.
    /// @return totalLoot Total $LOOT supply.
    /// @return cumBurned Cumulative $HEIST burned.
    function getGlobalState()
        external
        view
        returns (
            uint256 currentHeat,
            uint256 era,
            uint256 eraMul,
            uint256 cumBuyEth,
            uint256 lockup,
            uint256 treasury,
            uint256 totalLoot,
            uint256 cumBurned
        )
    {
        currentHeat = _peekDecayedHeat();
        era = currentEra;
        eraMul = eraMultiplier();
        cumBuyEth = cumulativeBuyVolumeETH;
        lockup = lockupFund;
        treasury = heistTreasuryETH;
        totalLoot = LOOT.totalSupply();
        cumBurned = cumulativeBurnedHEIST;
    }

    /// @notice ETH per 1e18 $LOOT at current treasury and supply.
    function getRedemptionRate() external view returns (uint256) {
        return LOOT.getRedemptionRate();
    }

    /// @notice Preview ETH paid for `lootAmount` $LOOT at current rate.
    function previewRedemption(uint256 lootAmount) external view returns (uint256) {
        return LOOT.previewRedemption(lootAmount);
    }

    /// @notice ETH cumulative buy volume needed to trigger the next era.
    function getNextEraThreshold() external view returns (uint256) {
        return nextEraThreshold();
    }

    /// @notice Paginated heist history.
    /// @param startId First heist id to return.
    /// @param count Max number of heists to return.
    /// @return outcomes Array of HeistOutcome.
    function getHeistHistory(uint256 startId, uint256 count)
        external
        view
        returns (HeistOutcome[] memory outcomes)
    {
        if (count == 0) return outcomes;
        uint256 last = currentHeistId;
        if (startId > last) return outcomes;
        uint256 available = last - startId + 1;
        uint256 n = count > available ? available : count;
        outcomes = new HeistOutcome[](n);
        for (uint256 i = 0; i < n; i++) {
            outcomes[i] = heistOutcome[startId + i];
        }
    }

    /// @notice Returns a preview of a buyer's expected entry into the current heist.
    /// @param buyer Buyer address (used to detect re-entry vs first entry).
    /// @param ethAmount ETH (wei) the buyer would spend.
    /// @return tier Timing tier they would be assigned (0..3) if first-time buyer this heist.
    /// @return shareOfScore Their fraction of total weighted contribution after this buy (1e18-scaled).
    /// @return lootIfClean Estimated $LOOT minted to them if the heist resolves clean.
    /// @return lootIfBusted Estimated $LOOT minted to them if the heist resolves busted.
    function previewHeistEntry(address buyer, uint256 ethAmount)
        external
        view
        returns (uint256 tier, uint256 shareOfScore, uint256 lootIfClean, uint256 lootIfBusted)
    {
        uint256 hid = currentHeistId;
        uint256 elapsed = block.number - heistStartBlock;
        if (crewJoined[hid][buyer]) {
            tier = crewTimingTier[hid][buyer];
        } else {
            uint256 t = (elapsed * 4) / HEIST_WINDOW_BLOCKS;
            if (t > 3) t = 3;
            tier = t;
        }
        uint256 buyerNewContrib = crewContribution[hid][buyer] + ethAmount;
        uint256 buyerWeight = (buyerNewContrib * timingMultiplier[tier]) / 1e18;
        uint256 weighted = _weightedSumWithDelta(hid, buyer, ethAmount, uint8(tier));
        if (weighted == 0) return (tier, 0, 0, 0);
        shareOfScore = (buyerWeight * 1e18) / weighted;

        uint256 currentHeat = _peekDecayedHeat();
        uint256 estTotalVol = heistBuyVolumeETH[hid] + ethAmount;
        uint256 score =
            (estTotalVol * _sqrt(currentHeat / 1e9) * eraMultiplier()) / 1e18 * SCORE_CONSTANT / 1e18;
        lootIfClean = ((score + lockupFund) * shareOfScore) / 1e18;
        lootIfBusted = ((score / 2) * shareOfScore) / 1e18;
    }

    /// @dev Weighted-sum recomputation when previewing a not-yet-recorded buy.
    function _weightedSumWithDelta(uint256 hid, address buyer, uint256 ethAmount, uint8 newTier)
        internal
        view
        returns (uint256 s)
    {
        address[] storage crew = _crewMembers[hid];
        bool foundBuyer = false;
        for (uint256 i = 0; i < crew.length; i++) {
            address m = crew[i];
            uint8 tier = crewTimingTier[hid][m];
            uint256 contrib = crewContribution[hid][m];
            if (m == buyer) {
                foundBuyer = true;
                contrib += ethAmount;
            }
            s += (contrib * timingMultiplier[tier]) / 1e18;
        }
        if (!foundBuyer) s += (ethAmount * timingMultiplier[newTier]) / 1e18;
    }

    /// @dev Returns the current heat with lazy decay applied (read-only).
    function _peekDecayedHeat() internal view returns (uint256 h) {
        uint256 elapsed = block.number - lastHeatUpdateBlock;
        if (elapsed == 0 || globalHeat == 0) return globalHeat;
        if (elapsed > 10_000) elapsed = 10_000;
        uint256 factor = _powDecay(elapsed);
        h = (globalHeat * factor) / 1e18;
    }

    /// @notice Allow the hook to receive ETH (treasury inflows from PoolManager.take).
    receive() external payable {}
}
