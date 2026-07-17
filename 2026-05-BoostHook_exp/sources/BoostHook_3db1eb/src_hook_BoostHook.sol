// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {BoostToken} from "../token/BoostToken.sol";
import {LDF} from "../library/LDF.sol";
import {IBoostStaking} from "../staking/BoostStaking.sol";

/// @title  BoostHook — Uniswap v4 hook for leveraged longs on a bonding-curve token.
/// @notice User deposits ETH collateral; hook borrows more ETH from fully-passed
///         bands, swaps `collateral + borrow` → TOKEN, holds the TOKEN. Close sells
///         the TOKEN, refills bands, returns surplus. Auto-liquidation in afterSwap
///         using a TWAP-gated health check.
contract BoostHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint16  public constant MAX_LEVERAGE              = 5;
    uint256 public constant LONG_CAP_BPS              = 4000;   // borrow cap per band: 40% of its capacity
    uint256 public constant BORROW_FEE_BPS            = 100;    // 1% of borrow, at open → stakers
    uint256 public constant SWAP_FEE_BPS              = 100;    // 1% of every direct spot swap → feeRecipient
    uint256 public constant CLOSE_FEE_BPS             = 100;    // 1% of close/liquidation surplus → feeRecipient
    uint256 public constant LIQUIDATION_HEALTH_BPS    = 10_500; // liquidate below 105% health
    uint256 public constant MIN_COLLATERAL_VALUE      = 0.01 ether;
    uint256 public constant CLOSE_COOLDOWN_BLOCKS     = 2;
    uint256 public constant NUM_INITIAL_BANDS         = 300;    // 5-ETH bands → covers curveEth 0..1500 (99.3% sold)
    uint256 public constant MAX_BORROW_BANDS          = 5;      // gas cap on the per-open borrow walk
    uint16  public constant MAX_LIQS_PER_SWAP         = 10;
    uint16  public constant MAX_SCAN_PER_SWAP         = 64;
    uint16  public constant MAX_LIQS_PER_BLOCK        = 5;      // bounds cross-swap liquidation cascades in one block
    uint16  public constant OBS_BUFFER_SIZE           = 64;
    uint32  public constant TWAP_SECONDS              = 300;    // liquidation health uses this TWAP window

    // ─── Errors ─────────────────────────────────────────────────────────────
    error NotOwner();
    error PoolMgrOnly();
    error PoolAlreadyInitialized();
    error PoolNotInitializedErr();
    error UnauthorizedLP();
    error ZeroAddress();
    error Reentrancy();
    error InvalidAction();
    error EthTransferFailed();
    error TokenSupplyMismatch();
    error InvalidPoolKey();
    error CollateralBelowMin();
    error InvalidLeverage();
    error NoOpenPosition();
    error NotPositionOwner();
    error CooldownActive();
    error CapBreached();
    error TickFull();
    error InsufficientBorrowCapacity();
    error BandAlreadySeeded();
    error UnauthorizedInit();
    error InvalidInitPrice();
    error ExactOutputDisallowed();
    error SlippageExceeded();
    error DeadlineExceeded();
    error NothingToClaim();
    error InvalidSellBps();
    error NothingSold();
    error PartialFill();
    error TradingNotEnabled();
    error ProtocolPaused();          // owner emergency stop — blocks new opens only
    error BadSeedRange();
    error ImpureBorrow();            // borrow band returned token1 — should be impossible
    error TokenTransferFailed();
    error StakingNotSet();
    error StakingAlreadySet();

    IPoolManager public immutable poolManager;
    BoostToken   public immutable token;
    address      public immutable owner;

    PoolKey public poolKey;
    bool    public poolInitialized;

    /// @notice Set true only once ALL bands are seeded. Swaps and opens revert
    ///         until then — blocks price discovery against a partially-seeded
    ///         curve if the deploy sequence is broadcast publicly mid-batches.
    bool    public tradingEnabled;
    uint256 public bandsSeededCount;

    /// @notice Owner emergency stop. When true, NEW leveraged opens revert.
    ///         Spot trading, closes, and liquidations are never affected.
    bool    public paused;

    /// @dev Receives the 1%-of-swap LP fee (claim via claim()). Hardcoded; not
    ///      exposed as a public getter. Borrow fees go to `staking`, not here.
    address internal constant feeRecipient = 0x98Fb2387eb8B5db1811D6789DE8c1e12546d994D;

    /// @notice V4 tick range + total L + outstanding borrowed-out ETH for a band.
    struct TickBand {
        int24   v4TickLower;
        int24   v4TickUpper;
        uint128 liquidity;
        uint256 borrowedETH;
    }
    mapping(uint256 bandId => TickBand) public bands;

    /// @notice Leveraged-long account. Debt is global — repaid on close into
    ///         whichever fully-passed bands still have outstanding `borrowedETH`
    ///         (nearest-active first). No per-position band tracking.
    struct Position {
        address owner;
        uint256 collateralETH;       // ETH input minus borrow fee
        uint256 debtETH;             // ETH owed back to bands on close
        uint256 holdingTOKEN;        // TOKEN held by hook as position collateral
        uint160 openSqrtPriceX96;    // spot at open (for liq-price display)
        uint8   leverage;            // 2..5
        uint64  openedAtBlock;
        uint128 realizedETHOut;      // lifetime ETH pulled via prior partial closes
    }
    mapping(uint256 positionId => Position) internal _positions;
    /// @notice Per-user list of currently-open position IDs. Entries are
    ///         swap-popped on full close/liquidation, so this stays bounded to
    ///         the user's *open* positions (history lives in `userHistory`).
    mapping(address => uint256[]) public userPositions;
    mapping(uint256 => uint256) internal _userPosIndex;
    uint256 public nextPositionId = 1;

    /// @notice Permanent record of a full close or liquidation. Position structs
    ///         are wiped on full close, so this is the only persistent trade
    ///         history. Partial closes update the live position, not this.
    enum HistoryKind { FullClose, Liquidated }
    struct ClosedPositionRecord {
        uint64  timestamp;
        uint64  positionId;
        uint8   leverage;
        HistoryKind kind;
        uint128 collateralETH;
        uint128 amountIn;        // tokens sold
        uint128 amountOut;       // lifetime ETH returned (partial + final)
    }
    mapping(address => ClosedPositionRecord[]) public userHistory;

    uint256[] internal _openIds;
    mapping(uint256 => uint256) internal _openIdIndex;
    uint256 internal _iterCursor;

    uint256 public totalDebtETH;
    uint256 public totalHoldingTOKEN;
    uint64  public launchBlock;
    bool    internal _inLiquidation;

    /// @notice Pull-based payouts. ETH owed accrues here; beneficiaries call
    ///         claim(). Prevents a malicious receive() from reverting hook flows.
    mapping(address => uint256) internal _claimable;

    /// @notice REAL ETH the hook holds that couldn't be re-LP'd during a
    ///         close/liquidation. Owner deploys it back via deployReserveToBands().
    ///         Invariant: protocolReserve <= address(this).balance.
    uint256 public protocolReserve;

    /// @notice Realized bad debt — write-off marker, NOT real ETH. Tracks the
    ///         gap between what bands lent out and what closes/liquidations
    ///         recovered. Invariant:
    ///         sum(band.borrowedETH) == totalDebtETH + protocolReserve + totalBadDebtETH.
    uint256 public totalBadDebtETH;

    /// @notice Receives 0.5%-of-borrow fees as ETH rewards. Set once via setStaking().
    IBoostStaking public staking;
    bool public stakingSet;

    /// @notice TWAP ring buffer. Liquidation health uses the TWAP tick, not raw
    ///         spot, so a single-block flash dump can't manufacture liquidations.
    struct Observation {
        uint32 timestamp;
        int56  tickCumulative;
        int24  tick;
        bool   initialized;
    }
    Observation[OBS_BUFFER_SIZE] internal _observations;
    uint16 public obsIndex;

    uint64 internal _lastLiqBlock;
    uint16 internal _liqsThisBlock;

    event BandSeeded(uint256 indexed bandId, int24 tickLower, int24 tickUpper, uint256 tokenAmount, uint128 liquidity);
    event PositionOpened(
        uint256 indexed id, address indexed owner,
        uint256 collateralETH, uint256 debtETH, uint256 holdingTOKEN
    );
    event PositionClosed(uint256 indexed id, address indexed owner, uint256 returnedETH);
    event PositionPartialClosed(
        uint256 indexed id, address indexed owner,
        uint256 tokensSold, uint256 debtRepaid, uint256 returnedETH,
        uint256 newHolding, uint256 newDebt
    );
    event PositionLiquidated(uint256 indexed id, address indexed owner, uint256 ethFromSell, uint256 returnedETH);
    event FeeToStakers(uint256 amount);
    event StakingSet(address indexed staking);
    event PausedSet(bool paused);
    event Claimed(address indexed user, uint256 amount);
    event ProtocolReserveAdded(uint256 amount, uint256 totalReserve);
    event BadDebtRealized(uint256 indexed positionId, uint256 amount, uint256 totalBadDebt);
    event StakingNotifyFailed(uint256 amount);

    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyPoolManager() { if (msg.sender != address(poolManager)) revert PoolMgrOnly(); _; }

    constructor(IPoolManager pm_, BoostToken token_, address owner_) {
        if (address(pm_) == address(0) || address(token_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = pm_;
        token = token_;
        owner = owner_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    receive() external payable {}

    /// @notice One-shot wiring of the staking contract; must precede the first openLong.
    function setStaking(address staking_) external onlyOwner {
        if (stakingSet) revert StakingAlreadySet();
        if (staking_ == address(0)) revert ZeroAddress();
        staking = IBoostStaking(staking_);
        stakingSet = true;
        emit StakingSet(staking_);
    }

    /// @notice Emergency stop for NEW leveraged opens only. Spot trading, closes,
    ///         and liquidations are never affected — users can always exit.
    function pause()   external onlyOwner { paused = true;  emit PausedSet(true);  }
    function unpause() external onlyOwner { paused = false; emit PausedSet(false); }

    /// @notice Withdraw all ETH owed to the caller (close PnL, liquidation remainder, LP fees).
    ///         No gas cap on the transfer — nonReentrant + the balance is keyed by msg.sender,
    ///         so an expensive receive() can only burn the caller's own gas, not grief anyone.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = _claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _claimable[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) {
            _claimable[msg.sender] = amount; // restore on failure
            revert EthTransferFailed();
        }
        emit Claimed(msg.sender, amount);
    }

    function claimable(address user) external view returns (uint256) {
        return _claimable[user];
    }

    /// @notice Re-LP accumulated `protocolReserve` ETH back into fully-passed
    ///         bands that still have outstanding `borrowedETH`. Whatever can't
    ///         be placed right now stays in reserve.
    function deployReserveToBands() external onlyOwner nonReentrant {
        if (protocolReserve == 0) revert NothingToClaim();
        uint256 amount = protocolReserve;
        protocolReserve = 0;
        bytes memory ret = poolManager.unlock(abi.encode(Action.DEPLOY_RESERVE, abi.encode(amount)));
        uint256 deployed = abi.decode(ret, (uint256));
        if (deployed < amount) protocolReserve = amount - deployed;
    }

    /// @notice Recapitalize bands using freshly-donated ETH. Whatever lands in
    ///         a band reduces `totalBadDebtETH` first (writing off the realized
    ///         loss), then any overshoot / undeployable remainder goes to
    ///         `protocolReserve`. Lets the protocol heal bad debt without
    ///         touching user funds.
    function donateAndRefillBands() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert NothingToClaim();
        bytes memory ret = poolManager.unlock(abi.encode(Action.DEPLOY_RESERVE, abi.encode(msg.value)));
        uint256 deployed = abi.decode(ret, (uint256));
        if (deployed >= totalBadDebtETH) {
            uint256 over = deployed - totalBadDebtETH;
            totalBadDebtETH = 0;
            if (over > 0) protocolReserve += over;
        } else {
            totalBadDebtETH -= deployed;
        }
        if (deployed < msg.value) protocolReserve += (msg.value - deployed);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                 true,
            afterInitialize:                  false,
            beforeAddLiquidity:               true,
            afterAddLiquidity:                false,
            beforeRemoveLiquidity:            true,
            afterRemoveLiquidity:             false,
            beforeSwap:                       true,
            afterSwap:                        true,
            beforeDonate:                     false,
            afterDonate:                      false,
            beforeSwapReturnDelta:            true,
            afterSwapReturnDelta:             true,
            afterAddLiquidityReturnDelta:     false,
            afterRemoveLiquidityReturnDelta:  false
        });
    }

    // ─── Pool setup ─────────────────────────────────────────────────────────
    function initializePool() external onlyOwner {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (token.balanceOf(address(this)) != LDF.TOTAL_SUPPLY) revert TokenSupplyMismatch();

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee:       0, // hook applies its own 1% fee
            tickSpacing: LDF.TICK_SPACING,
            hooks:     IHooks(address(this))
        });
        poolKey = key;

        (, int24 band0TickUpper) = LDF.bandToV4Ticks(0);
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(band0TickUpper);
        poolManager.initialize(key, initialSqrtPriceX96);
        poolInitialized = true;
        launchBlock = uint64(block.number);

        // Pre-seed the TWAP ring with two synthetic observations spanning the
        // window at the initial tick — without this, no liquidations could fire
        // for the first TWAP_SECONDS after deploy (a leverage-abuse window).
        uint32 nowTs = uint32(block.timestamp);
        uint32 span  = TWAP_SECONDS + 60;
        _observations[0] = Observation({
            timestamp:      nowTs > span ? nowTs - span : 0,
            tickCumulative: 0,
            tick:           band0TickUpper,
            initialized:    true
        });
        _observations[1] = Observation({
            timestamp:      nowTs,
            tickCumulative: int56(band0TickUpper) * int56(uint56(span)),
            tick:           band0TickUpper,
            initialized:    true
        });
        obsIndex = 1;
    }

    function seedBands(uint256 fromBand, uint256 toBand) external onlyOwner nonReentrant {
        if (!poolInitialized) revert PoolNotInitializedErr();
        if (toBand > NUM_INITIAL_BANDS || fromBand >= toBand) revert BadSeedRange();
        poolManager.unlock(abi.encode(Action.SEED_BANDS, abi.encode(fromBand, toBand)));
        bandsSeededCount += (toBand - fromBand);
        if (!tradingEnabled && bandsSeededCount == NUM_INITIAL_BANDS) tradingEnabled = true;
    }

    // ─── Hook callbacks ─────────────────────────────────────────────────────
    /// @dev Only the hook may initialize the pool, and only at band-0's tickUpper.
    ///      Blocks an attacker from front-running initializePool() with a hostile price.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != address(this)) revert UnauthorizedInit();
        if (Currency.unwrap(key.currency0) != address(0))    revert InvalidPoolKey();
        if (Currency.unwrap(key.currency1) != address(token)) revert InvalidPoolKey();
        if (key.fee != 0)                                    revert InvalidPoolKey();
        if (key.tickSpacing != LDF.TICK_SPACING)             revert InvalidPoolKey();
        if (address(key.hooks) != address(this))             revert InvalidPoolKey();
        (, int24 expectedUpper) = LDF.bandToV4Ticks(0);
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(expectedUpper)) revert InvalidInitPrice();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != address(this)) revert UnauthorizedLP();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != address(this)) revert UnauthorizedLP();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice 1% ETH fee on BUY (zeroForOne=true). Exact-input only; exact-output disallowed.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender == address(this)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // M-03 fix: block external swaps until all bands are seeded.
        if (!tradingEnabled) revert TradingNotEnabled();
        // Block exact-output swaps entirely — would otherwise bypass the fee logic
        // and complicate slippage accounting. Real users use exact-input via aggregators.
        if (params.amountSpecified > 0) revert ExactOutputDisallowed();
        // L-01 fix (audit-12): cap amountIn to a sane range so casts can't overflow.
        // int256.min (-2^255) would underflow when negated. Also any input that
        // makes `fee` exceed int128.max would corrupt the BeforeSwapDelta cast.
        if (params.amountSpecified == type(int256).min) revert ExactOutputDisallowed();

        if (!params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fee = (amountIn * SWAP_FEE_BPS) / 10000;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // L-01 fix (audit-12): the fee is encoded as int128 in BeforeSwapDelta.
        // For any sane real-world swap this is automatic, but guard explicitly
        // so we never silently truncate.
        if (fee > uint256(uint128(type(int128).max))) revert ExactOutputDisallowed();

        // Pull-based: credit fee to feeRecipient instead of pushing
        poolManager.take(key.currency0, address(this), fee);
        _claimable[feeRecipient] += fee;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @notice 1% ETH fee on SELL + auto-liquidation scan.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyPoolManager returns (bytes4, int128)
    {
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);

        // Scan before write: liquidation health must use the TWAP that excludes
        // the just-completed swap, otherwise a flash dump pollutes its own TWAP.
        if (!_inLiquidation) {
            _scanAndLiquidate();
        }
        _writeObservation();

        // Fee skim on SELL (only for exact-input; exact-output rejected in beforeSwap)
        if (params.zeroForOne)              return (IHooks.afterSwap.selector, 0);
        if (params.amountSpecified >= 0)    return (IHooks.afterSwap.selector, 0);

        int128 ethOut = delta.amount0();
        if (ethOut <= 0) return (IHooks.afterSwap.selector, 0);

        uint256 fee = (uint256(uint128(ethOut)) * SWAP_FEE_BPS) / 10000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Pull-based: credit fee to feeRecipient
        poolManager.take(key.currency0, address(this), fee);
        _claimable[feeRecipient] += fee;
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert InvalidAction(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert InvalidAction(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert InvalidAction(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert InvalidAction(); }

    // ─── User entry points ──────────────────────────────────────────────────

    /// @notice Open a leveraged long. `minHoldingOut` is the slippage floor on
    ///         the leveraged-buy output. `deadline` is a unix timestamp.
    function openLong(uint256 leverage, uint256 minHoldingOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 positionId, uint256 holdingOut)
    {
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (!poolInitialized) revert PoolNotInitializedErr();
        if (!tradingEnabled) revert TradingNotEnabled();
        if (paused) revert ProtocolPaused();
        if (!stakingSet) revert StakingNotSet();
        if (leverage < 2 || leverage > MAX_LEVERAGE) revert InvalidLeverage();
        if (msg.value < MIN_COLLATERAL_VALUE) revert CollateralBelowMin();

        uint256 collateral = msg.value;
        uint256 borrowEth  = collateral * (leverage - 1);
        uint256 borrowFee  = (borrowEth * BORROW_FEE_BPS) / 10_000;
        uint256 effectiveCol = collateral - borrowFee;

        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId());

        // Handler walks fully-passed bands farthest-first, removes ETH-only L
        // from each up to its 40% cap, then swaps `effectiveCol + borrow` → TOKEN.
        bytes memory ret = poolManager.unlock(abi.encode(
            Action.OPEN_LONG,
            abi.encode(borrowEth, effectiveCol, borrowFee, msg.sender)
        ));
        (uint256 actualBorrowed, uint256 swapTokensOut) = abi.decode(ret, (uint256, uint256));

        if (swapTokensOut < minHoldingOut) revert SlippageExceeded();

        positionId = nextPositionId++;
        _positions[positionId] = Position({
            owner:             msg.sender,
            collateralETH:     effectiveCol,
            debtETH:           actualBorrowed,
            holdingTOKEN:      swapTokensOut,
            openSqrtPriceX96:  sqrtP,
            leverage:          uint8(leverage),
            openedAtBlock:     uint64(block.number),
            realizedETHOut:    0
        });
        _userPosIndex[positionId] = userPositions[msg.sender].length;
        userPositions[msg.sender].push(positionId);
        _openIdIndex[positionId] = _openIds.length;
        _openIds.push(positionId);

        totalDebtETH      += actualBorrowed;
        totalHoldingTOKEN += swapTokensOut;
        holdingOut         = swapTokensOut;

        emit PositionOpened(positionId, msg.sender, effectiveCol, actualBorrowed, swapTokensOut);
    }

    /// @notice Close `sellBps` (1..10000) of a position. Debt-first: tokens
    ///         sold → ETH → repay bands → surplus to user (pull payment).
    ///         A full close requires the full requested tokens to actually sell
    ///         (no partial-fill debt forgiveness — audit H-02).
    function close(uint256 positionId, uint256 sellBps, uint256 minEthOut, uint256 deadline)
        external nonReentrant
        returns (uint256 returnedETH, uint256 actualTokenSold)
    {
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (sellBps == 0 || sellBps > 10_000) revert InvalidSellBps();

        Position storage pos = _positions[positionId];
        if (pos.debtETH == 0 && pos.holdingTOKEN == 0) revert NoOpenPosition();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        if (block.number < pos.openedAtBlock + CLOSE_COOLDOWN_BLOCKS) revert CooldownActive();

        uint256 holding = pos.holdingTOKEN;
        uint256 debt    = pos.debtETH;
        address pOwner  = pos.owner;
        // Snapshot before any mutation / _removePosition.
        uint8   posLeverage      = pos.leverage;
        uint256 posCollateralETH = pos.collateralETH;
        uint128 posRealizedOut   = pos.realizedETHOut;

        uint256 tokensToSell = sellBps == 10_000 ? holding : (holding * sellBps) / 10_000;
        if (tokensToSell == 0) revert InvalidSellBps();
        bytes memory ret = poolManager.unlock(abi.encode(
            Action.CLOSE,
            abi.encode(tokensToSell, debt, pOwner)
        ));
        uint256 paidToDebt;
        (returnedETH, actualTokenSold, paidToDebt) =
            abi.decode(ret, (uint256, uint256, uint256));

        if (actualTokenSold == 0) revert NothingSold();
        // Full close must sell the full requested tokens — a partial fill would
        // delete the position AND write off remaining debt, an exit subsidy for
        // insolvent users in thin liquidity. Caller retries with smaller sellBps.
        if (actualTokenSold < tokensToSell) revert PartialFill();
        if (returnedETH < minEthOut) revert SlippageExceeded();

        totalDebtETH      -= paidToDebt;
        totalHoldingTOKEN -= actualTokenSold;

        uint256 newHolding = holding - actualTokenSold;
        uint256 newDebt    = debt - paidToDebt;
        bool fullClose = sellBps == 10_000 || newHolding == 0;

        if (fullClose) {
            // Holding fully sold but ETH out < debt: the shortfall is realized
            // loss (no ETH backs it). Track in totalBadDebtETH, NOT
            // protocolReserve — crediting phantom ETH to the reserve would brick
            // deployReserveToBands() (settle{value:} on ETH never received).
            if (newDebt > 0) {
                totalBadDebtETH += newDebt;
                totalDebtETH    -= newDebt;
                emit BadDebtRealized(positionId, newDebt, totalBadDebtETH);
            }
            // History record before _removePosition wipes the struct.
            uint256 lifetimeOut = uint256(posRealizedOut) + returnedETH;
            _recordHistory(pOwner, positionId, posLeverage, posCollateralETH, actualTokenSold, lifetimeOut, HistoryKind.FullClose);
            _removePosition(positionId);
            emit PositionClosed(positionId, pOwner, returnedETH);
        } else {
            pos.holdingTOKEN = newHolding;
            pos.debtETH      = newDebt;
            if (returnedETH > 0) pos.realizedETHOut += uint128(returnedETH);
            emit PositionPartialClosed(positionId, pOwner, actualTokenSold, paidToDebt, returnedETH, newHolding, newDebt);
        }
    }

    // ─── Auto-liquidation ───────────────────────────────────────────────────
    /// @dev Defense layers:
    ///       (A) health uses the TWAP tick (not spot) — a single-block dump
    ///           can't flip a healthy position to liquidatable;
    ///       (B) liquidations per block are capped — bounds any cascade.
    ///      The forced sell itself is uncapped (MAX_SQRT_PRICE − 1, same as a
    ///      user close): a liquidation must fully clear the position in one swap,
    ///      never dribble it out across blocks. A momentary dump below the curve
    ///      is self-correcting via arbitrage; what matters is that the position
    ///      stops accruing bad debt promptly.
    function _scanAndLiquidate() internal {
        uint256 n = _openIds.length;
        if (n == 0) return;

        // If the TWAP buffer isn't warm enough, skip — safer to delay
        // liquidations than to use manipulable spot.
        (int24 twapTick, bool twapOk) = _twapTick(TWAP_SECONDS);
        if (!twapOk) return;
        uint160 healthSqrtP = TickMath.getSqrtPriceAtTick(twapTick);

        if (uint64(block.number) != _lastLiqBlock) {
            _lastLiqBlock = uint64(block.number);
            _liqsThisBlock = 0;
        }
        if (_liqsThisBlock >= MAX_LIQS_PER_BLOCK) return;
        uint256 blockRemaining = MAX_LIQS_PER_BLOCK - _liqsThisBlock;

        // Bound liquidations AND positions scanned per call; cursor advances so
        // the whole set is eventually checked.
        uint256 scanBudget = n < MAX_SCAN_PER_SWAP ? n : MAX_SCAN_PER_SWAP;
        uint256 maxLiq    = scanBudget < MAX_LIQS_PER_SWAP ? scanBudget : MAX_LIQS_PER_SWAP;
        if (maxLiq > blockRemaining) maxLiq = blockRemaining;

        uint256[] memory toLiq = new uint256[](maxLiq);
        uint256 count = 0;
        uint256 cursor = _iterCursor % n;
        uint256 scanned = 0;
        for (uint256 i = 0; i < scanBudget && count < maxLiq; i++) {
            uint256 idx = (cursor + i) % n;
            uint256 posId = _openIds[idx];
            Position storage p = _positions[posId];
            uint256 holdingValueEth = _tokenValueInEth(p.holdingTOKEN, healthSqrtP);
            uint256 healthBps = (holdingValueEth * 10_000) / (p.debtETH == 0 ? 1 : p.debtETH);
            if (healthBps < LIQUIDATION_HEALTH_BPS) toLiq[count++] = posId;
            scanned = i + 1;
        }
        _iterCursor = (cursor + scanned) % (n > 0 ? n : 1);

        if (count == 0) return;

        _inLiquidation = true;
        for (uint256 i = 0; i < count; i++) {
            _liquidateInternal(toLiq[i]);
        }
        _inLiquidation = false;
        _liqsThisBlock += uint16(count);
    }

    function _liquidateInternal(uint256 positionId) internal {
        Position storage pos = _positions[positionId];
        uint256 holding = pos.holdingTOKEN;
        uint256 debt    = pos.debtETH;
        address pOwner = pos.owner;
        // Snapshot before _removePosition wipes the struct.
        uint8   posLeverage      = pos.leverage;
        uint256 posCollateralETH = pos.collateralETH;
        uint128 posRealizedOut   = pos.realizedETHOut;

        totalDebtETH      -= debt;
        totalHoldingTOKEN -= holding;
        _removePosition(positionId);

        // Runs inside afterSwap (already unlocked) — direct PM calls, no recursive
        // unlock. Uncapped sell (MAX_SQRT_PRICE − 1): clear the whole position in
        // one swap. Never reverts on zero output (a toxic position can't DoS the
        // swap that triggers it).
        (uint256 ethFromSell, uint256 actualTokenSold) = _swapTokenForEth(holding, TickMath.MAX_SQRT_PRICE - 1);

        // Pathological edge only (entire curve drained → price floored): any
        // unsold remainder stays in the hook; re-track it so accounting matches.
        uint256 unsoldTokens = holding - actualTokenSold;
        if (unsoldTokens > 0) totalHoldingTOKEN += unsoldTokens;

        // Refill debt-repayment across borrowed bands (nearest-active first).
        uint256 forRefill = debt < ethFromSell ? debt : ethFromSell;
        uint256 spent = forRefill > 0 ? _refillAcrossBands(forRefill) : 0;

        // Real ETH that couldn't be re-LP'd right now → reserve.
        uint256 unabsorbedRefill = forRefill > spent ? forRefill - spent : 0;
        if (unabsorbedRefill > 0) {
            protocolReserve += unabsorbedRefill;
            emit ProtocolReserveAdded(unabsorbedRefill, protocolReserve);
        }

        // ethFromSell < debt → realized loss; bands carry unbacked borrowedETH.
        uint256 badDebt = debt > ethFromSell ? debt - ethFromSell : 0;
        if (badDebt > 0) {
            totalBadDebtETH += badDebt;
            emit BadDebtRealized(positionId, badDebt, totalBadDebtETH);
        }

        // Surplus → user (rare in liquidations), minus the 1% close fee on the surplus → stakers.
        uint256 returnedETH = ethFromSell > debt ? ethFromSell - debt : 0;
        if (returnedETH > 0) {
            uint256 closeFee = (returnedETH * CLOSE_FEE_BPS) / 10_000;
            if (closeFee > 0) {
                _routeFeeToStakers(closeFee);
                returnedETH -= closeFee;
            }
            _claimable[pOwner] += returnedETH;
        }

        uint256 lifetimeOut = uint256(posRealizedOut) + returnedETH;
        _recordHistory(pOwner, positionId, posLeverage, posCollateralETH, actualTokenSold, lifetimeOut, HistoryKind.Liquidated);
        emit PositionLiquidated(positionId, pOwner, ethFromSell, returnedETH);
    }

    // ─── Unlock callback ────────────────────────────────────────────────────
    enum Action { SEED_BANDS, OPEN_LONG, CLOSE, DEPLOY_RESERVE }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));

        if (action == Action.SEED_BANDS) {
            (uint256 fromBand, uint256 toBand) = abi.decode(payload, (uint256, uint256));
            for (uint256 i = fromBand; i < toBand; i++) _seedSingleBand(i);
            return "";
        } else if (action == Action.OPEN_LONG) {
            return _handleOpenLong(payload);
        } else if (action == Action.CLOSE) {
            return _handleClose(payload);
        } else if (action == Action.DEPLOY_RESERVE) {
            return _handleDeployReserve(payload);
        }
        revert InvalidAction();
    }

    function _handleOpenLong(bytes memory payload) internal returns (bytes memory) {
        (uint256 borrowEth, uint256 effectiveCol, uint256 borrowFee, address longUser) =
            abi.decode(payload, (uint256, uint256, uint256, address));

        (, int24 currentTick,,) = poolManager.getSlot0(_poolId());

        // Borrow walk: fully-passed bands farthest-first, ETH-only single-sided
        // removal from each (so modifyLiquidity returns zero token1 — asserted).
        // The active band is skipped (`v4TickLower <= currentTick`). Per-band
        // cap = 40% × TICK_WIDTH_ETH of cumulative outstanding.
        uint256 capPerBand = (LDF.TICK_WIDTH_ETH * LONG_CAP_BPS) / 10_000;
        // modifyLiquidity rounds down ~1 wei per band, so the walk lands a few
        // wei short of borrowEth. `dustTol` (1 gwei) is both the loop stop
        // condition and the acceptance margin below — a residual ≤ this counts
        // as satisfied.
        //
        // `minBandTake` is a SEPARATE, much smaller threshold: skip a band whose
        // remaining headroom is below it (a sub-`minBandTake` removal would round
        // `a0` to 0 → ImpureBorrow; it's also not worth a band slot). Crucially
        // it's tiny enough that even if ALL NUM_INITIAL_BANDS bands were skipped,
        // the wasted capacity (≤ NUM_INITIAL_BANDS × minBandTake = 3e6 wei) stays
        // far below `dustTol` — so no distribution of band `borrowedETH` values,
        // however the partial-refill arithmetic lands them, can ever make a
        // legitimate open spuriously revert. (1e4 is ~1000× above the single-
        // digit-wei zone where the removal rounds to 0.)
        uint256 dustTol     = 1 gwei;
        uint256 minBandTake = 1e4;
        uint256 remaining = borrowEth;
        uint256 totalFreedETH;
        uint256 slotsUsed;

        for (uint256 bandId = 0; bandId < NUM_INITIAL_BANDS && remaining > dustTol; bandId++) {
            if (slotsUsed >= MAX_BORROW_BANDS) break;
            TickBand storage band = bands[bandId];
            if (band.liquidity == 0) continue;
            if (band.v4TickLower <= currentTick) continue;

            uint256 alreadyOwed = band.borrowedETH;
            if (alreadyOwed >= capPerBand) continue;
            uint256 avail = capPerBand - alreadyOwed;
            uint256 take  = remaining < avail ? remaining : avail;
            if (take < minBandTake) continue; // band ~full — too little to bother

            uint128 lToRemove = LDF.liquidityForEthOnly(band.v4TickLower, band.v4TickUpper, take);
            if (lToRemove == 0 || lToRemove > band.liquidity) continue;

            (BalanceDelta remDelta,) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: band.v4TickLower,
                    tickUpper: band.v4TickUpper,
                    liquidityDelta: -int256(uint256(lToRemove)),
                    salt: bytes32(0)
                }),
                ""
            );
            int128 a0 = remDelta.amount0();
            int128 a1 = remDelta.amount1();
            if (a0 <= 0 || a1 != 0) revert ImpureBorrow();
            uint256 freed = uint256(uint128(a0));
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), freed);

            band.liquidity   -= lToRemove;
            band.borrowedETH += freed;
            totalFreedETH    += freed;
            remaining = remaining > freed ? remaining - freed : 0;
            slotsUsed++;
        }

        if (totalFreedETH + dustTol < borrowEth) revert InsufficientBorrowCapacity();

        // Leveraged swap. Must fully consume swapInput — refunding unspent input
        // would leak borrowed band-ETH to the user while debt stays on the books.
        uint256 swapInput = effectiveCol + totalFreedETH;
        (uint256 swapTokensOut, uint256 swapEthSpent) = _swapEthForToken(swapInput);
        if (swapEthSpent < swapInput) revert PartialFill();

        _routeFeeToStakers(borrowFee); // 1% origination → stakers (fallback if bricked)

        return abi.encode(totalFreedETH, swapTokensOut);
    }

    function _handleClose(bytes memory payload) internal returns (bytes memory) {
        (uint256 tokensToSell, uint256 debt, address pOwner) =
            abi.decode(payload, (uint256, uint256, address));

        // Sell tokens → ETH. The caller's minEthOut covers slippage, so no
        // sqrtPriceLimit cap here.
        (uint256 ethFromSell, uint256 actualTokenSold) =
            _swapTokenForEth(tokensToSell, TickMath.MAX_SQRT_PRICE - 1);

        // Refill bands (nearest-active first, capped at debt). Unplaceable ETH → reserve.
        uint256 forRefill = debt < ethFromSell ? debt : ethFromSell;
        uint256 spent = forRefill > 0 ? _refillAcrossBands(forRefill) : 0;
        uint256 unabsorbed = forRefill > spent ? forRefill - spent : 0;
        if (unabsorbed > 0) {
            protocolReserve += unabsorbed;
            emit ProtocolReserveAdded(unabsorbed, protocolReserve);
        }

        // Surplus → user, minus a 1% close fee on the surplus → stakers.
        // Fee is taken from the surplus only, so debt repayment is never reduced
        // and a losing close (no surplus) pays nothing.
        uint256 toUser = ethFromSell > debt ? ethFromSell - debt : 0;
        if (toUser > 0) {
            uint256 closeFee = (toUser * CLOSE_FEE_BPS) / 10_000;
            if (closeFee > 0) {
                _routeFeeToStakers(closeFee);
                toUser -= closeFee;
            }
            _claimable[pOwner] += toUser;
        }

        // `toUser` is now NET of the close fee — that's what the caller checks
        // against minEthOut and records as realized payout. `forRefill` is the
        // debt paid (reserve absorbs any L gap).
        return abi.encode(toUser, actualTokenSold, forRefill);
    }

    function _handleDeployReserve(bytes memory payload) internal returns (bytes memory) {
        uint256 amount = abi.decode(payload, (uint256));
        uint256 spent = amount > 0 ? _refillAcrossBands(amount) : 0;
        return abi.encode(spent);
    }

    function _currentTick() internal view returns (int24) {
        (, int24 t,,) = poolManager.getSlot0(_poolId());
        return t;
    }

    /// @dev Send `amount` ETH to the staking contract as a reward. If staking is
    ///      bricked, fall back to the LP fee address — never revert the caller.
    function _routeFeeToStakers(uint256 amount) internal {
        if (amount == 0) return;
        try staking.notifyReward{value: amount}() {
            emit FeeToStakers(amount);
        } catch {
            _claimable[feeRecipient] += amount;
            emit StakingNotifyFailed(amount);
        }
    }

    // ─── TWAP observation machinery ─────────────────────────────────────────

    /// @dev Append a new observation. Called from afterSwap. Bandwidth is
    ///      1 observation/second max — multiple swaps in the same block
    ///      collapse to one entry.
    function _writeObservation() internal {
        uint32 nowTs = uint32(block.timestamp);
        Observation memory last = _observations[obsIndex];

        if (last.initialized && last.timestamp == nowTs) {
            return; // already written this second
        }

        int24 curTick = _currentTick();
        int56 newCum;
        if (last.initialized) {
            // Tick was held constant at `last.tick` over [last.timestamp, nowTs].
            int56 delta = int56(last.tick) * int56(uint56(nowTs - last.timestamp));
            newCum = last.tickCumulative + delta;
        }

        uint16 nextIdx = uint16((uint256(obsIndex) + 1) % OBS_BUFFER_SIZE);
        _observations[nextIdx] = Observation({
            timestamp:      nowTs,
            tickCumulative: newCum,
            tick:           curTick,
            initialized:    true
        });
        obsIndex = nextIdx;
    }

    /// @dev TWAP tick over the past `secondsAgo`. Returns ok=false if the
    ///      buffer doesn't have enough history (safe fallback: caller skips
    ///      whatever action depended on it — e.g., liquidation).
    function _twapTick(uint32 secondsAgo) internal view returns (int24 avgTick, bool ok) {
        Observation memory current = _observations[obsIndex];
        if (!current.initialized) return (0, false);

        uint32 endTime = current.timestamp;
        if (endTime < secondsAgo) return (0, false);
        uint32 target = endTime - secondsAgo;

        // Walk backward through ring until we find an obs at-or-before `target`.
        Observation memory past;
        bool found;
        for (uint256 i = 1; i < OBS_BUFFER_SIZE; ++i) {
            uint256 idx = (uint256(obsIndex) + OBS_BUFFER_SIZE - i) % OBS_BUFFER_SIZE;
            Observation memory o = _observations[idx];
            if (!o.initialized) break;
            if (o.timestamp <= target) {
                past = o;
                found = true;
                break;
            }
        }
        if (!found) return (0, false); // buffer doesn't reach back far enough

        uint32 elapsed = endTime - past.timestamp;
        if (elapsed == 0) return (current.tick, true); // shouldn't happen but defensive

        int56 cumDiff = current.tickCumulative - past.tickCumulative;
        avgTick = int24(cumDiff / int56(uint56(elapsed)));
        ok = true;
    }

    /// @notice External view for frontend/inspection.
    function getTwapTick(uint32 secondsAgo) external view returns (int24 tick, bool ok) {
        return _twapTick(secondsAgo);
    }

    function _seedSingleBand(uint256 bandId) internal {
        // Re-seeding would double the v4 LP while overwriting accounting — guard.
        if (bands[bandId].liquidity != 0) revert BandAlreadySeeded();

        (int24 tickLower, int24 tickUpper) = LDF.bandToV4Ticks(bandId);
        uint256 tokenAlloc = LDF.loopAllocForBand(bandId);
        uint128 liquidity = LDF.liquidityForLoopOnly(tickLower, tickUpper, tokenAlloc);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int128(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        int128 a1 = delta.amount1();
        if (a1 < 0) {
            uint256 owed = uint256(uint128(-a1));
            poolManager.sync(poolKey.currency1);
            if (!token.transfer(address(poolManager), owed)) revert TokenTransferFailed();
            poolManager.settle();
        }

        bands[bandId] = TickBand({
            v4TickLower: tickLower,
            v4TickUpper: tickUpper,
            liquidity:   liquidity,
            borrowedETH: 0
        });
        emit BandSeeded(bandId, tickLower, tickUpper, tokenAlloc, liquidity);
    }

    // ─── Internal helpers ───────────────────────────────────────────────────

    /// @dev ETH→TOKEN swap. Settles the actual amount0 owed; never reverts on
    ///      zero output — caller handles partial/zero fills.
    function _swapEthForToken(uint256 ethIn)
        internal
        returns (uint256 tokensOut, uint256 actualEthSpent)
    {
        if (ethIn == 0) return (0, 0);
        BalanceDelta d = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        int128 ethDelta = d.amount0();
        int128 tokDelta = d.amount1();

        if (ethDelta < 0) {
            actualEthSpent = uint256(uint128(-ethDelta));
            poolManager.settle{value: actualEthSpent}();
        }
        if (tokDelta > 0) {
            tokensOut = uint256(uint128(tokDelta));
            poolManager.take(poolKey.currency1, address(this), tokensOut);
        }
    }

    /// @dev TOKEN→ETH swap. Never reverts on zero output (a toxic position can't
    ///      DoS the swap that triggers its liquidation). `sqrtPriceLimitX96`
    ///      caps the post-swap price: MAX-1 = "no limit" (user closes),
    ///      TWAP-derived bound = liquidations (anti-sandwich).
    function _swapTokenForEth(uint256 tokenIn, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 ethOut, uint256 actualTokenSold)
    {
        if (tokenIn == 0) return (0, 0);
        BalanceDelta d = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );
        int128 tokDelta = d.amount1();
        int128 ethDelta = d.amount0();

        if (tokDelta < 0) {
            actualTokenSold = uint256(uint128(-tokDelta));
            poolManager.sync(poolKey.currency1);
            if (!token.transfer(address(poolManager), actualTokenSold)) revert TokenTransferFailed();
            poolManager.settle();
        }
        if (ethDelta > 0) {
            ethOut = uint256(uint128(ethDelta));
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), ethOut);
        }
    }

    /// @notice Re-LP `budget` ETH across fully-passed bands with outstanding
    ///         `borrowedETH`, nearest-active first. Returns ETH actually placed.
    function _refillAcrossBands(uint256 budget) internal returns (uint256 totalSpent) {
        if (budget == 0) return 0;
        (, int24 currentTick,,) = poolManager.getSlot0(_poolId());

        uint256 remaining = budget;
        for (uint256 i = NUM_INITIAL_BANDS; i > 0 && remaining > 0; i--) {
            uint256 bandId = i - 1;
            TickBand storage band = bands[bandId];
            if (band.borrowedETH == 0) continue;
            if (band.v4TickLower <= currentTick) continue; // not fully-passed

            uint256 owed = band.borrowedETH;
            uint256 put  = remaining < owed ? remaining : owed;

            uint128 lToAdd = LDF.liquidityForEthOnly(band.v4TickLower, band.v4TickUpper, put);
            if (lToAdd == 0) continue;

            (BalanceDelta lpDelta,) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: band.v4TickLower,
                    tickUpper: band.v4TickUpper,
                    liquidityDelta: int256(uint256(lToAdd)),
                    salt: bytes32(0)
                }),
                ""
            );
            int128 owed0 = lpDelta.amount0();
            if (owed0 < 0) {
                uint256 spent = uint256(uint128(-owed0));
                poolManager.settle{value: spent}();
                band.liquidity += lToAdd;
                if (band.borrowedETH >= spent) band.borrowedETH -= spent;
                else band.borrowedETH = 0;
                if (remaining >= spent) remaining -= spent;
                else remaining = 0;
                totalSpent += spent;
            }
        }
    }

    function _removePosition(uint256 id) internal {
        address pOwner = _positions[id].owner;

        // swap-pop from the global open list
        uint256 idx = _openIdIndex[id];
        uint256 last = _openIds.length - 1;
        if (idx != last) {
            uint256 lastId = _openIds[last];
            _openIds[idx] = lastId;
            _openIdIndex[lastId] = idx;
        }
        _openIds.pop();
        delete _openIdIndex[id];

        // swap-pop from the owner's open list
        uint256[] storage up = userPositions[pOwner];
        uint256 uIdx = _userPosIndex[id];
        uint256 uLast = up.length - 1;
        if (uIdx != uLast) {
            uint256 lastUid = up[uLast];
            up[uIdx] = lastUid;
            _userPosIndex[lastUid] = uIdx;
        }
        up.pop();
        delete _userPosIndex[id];

        delete _positions[id];
    }

    /// @dev Append a permanent close/liquidation record. PnL = amountOut - collateralETH.
    function _recordHistory(
        address user,
        uint256 positionId,
        uint8 leverage,
        uint256 collateralETH,
        uint256 amountIn,
        uint256 amountOut,
        HistoryKind kind
    ) internal {
        userHistory[user].push(ClosedPositionRecord({
            timestamp:     uint64(block.timestamp),
            positionId:    uint64(positionId),
            leverage:      leverage,
            kind:          kind,
            collateralETH: uint128(collateralETH),
            amountIn:      uint128(amountIn),
            amountOut:     uint128(amountOut)
        }));
    }

    /// @dev TOKEN value in ETH at given sqrtPriceX96, computed safely without
    ///      overflowing on near-MAX sqrtP values. Two-step FullMath approach.
    function _tokenValueInEth(uint256 tokenAmount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        // ethValue = tokenAmount × (2^96 / sqrtP) × (2^96 / sqrtP)
        uint256 step1 = FullMath.mulDiv(tokenAmount, 1 << 96, uint256(sqrtPriceX96));
        return FullMath.mulDiv(step1, 1 << 96, uint256(sqrtPriceX96));
    }

    function _poolId() internal view returns (PoolId) {
        return PoolIdLibrary.toId(poolKey);
    }

    // ─── Views ──────────────────────────────────────────────────────────────
    function positions(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function openIdsLength() external view returns (uint256) {
        return _openIds.length;
    }

    function currentSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(_poolId());
    }

    // ─── Frontend aggregate views ───────────────────────────────────────────

    struct PoolSnapshot {
        uint160 sqrtPriceX96;
        int24   currentTick;
        uint256 cumulativeEthInPool;     // curveEth implied by spot
        uint256 totalDebtETH;
        uint256 totalBadDebtETH;
        uint256 totalHoldingTOKEN;
        uint256 numOpenPositions;
        uint256 totalSupply;
        bool    poolInitialized;
        bool    tradingEnabled;
        uint64  launchBlock;
    }

    function getPoolSnapshot() external view returns (PoolSnapshot memory s) {
        if (poolInitialized) {
            (s.sqrtPriceX96, s.currentTick,,) = poolManager.getSlot0(_poolId());
            s.cumulativeEthInPool = LDF.ethAtSqrtPrice(s.sqrtPriceX96);
        }
        s.totalDebtETH = totalDebtETH;
        s.totalBadDebtETH = totalBadDebtETH;
        s.totalHoldingTOKEN = totalHoldingTOKEN;
        s.numOpenPositions = _openIds.length;
        s.totalSupply = LDF.TOTAL_SUPPLY;
        s.poolInitialized = poolInitialized;
        s.tradingEnabled = tradingEnabled;
        s.launchBlock = launchBlock;
    }

    struct PositionView {
        uint256 id;
        address owner;
        uint256 collateralETH;
        uint256 debtETH;
        uint256 holdingTOKEN;
        uint64  openedAtBlock;
        uint256 currentValueEth;     // holding value at current price
        uint256 healthBps;           // 10_000 = 100%; <10_500 = liquidatable
        bool    liquidatable;
        uint256 liquidationEth;      // pool ETH at which liquidation triggers
    }

    function getPosition(uint256 id) public view returns (PositionView memory v) {
        Position storage p = _positions[id];
        // L-01 fix: include positions where debt was fully repaid but holding
        // remains (e.g., partial close exceeding debt). The user can still
        // call close() to recover that holding, so views must surface it.
        if (p.owner == address(0)) return v;
        if (p.debtETH == 0 && p.holdingTOKEN == 0) return v;

        v.id = id;
        v.owner = p.owner;
        v.collateralETH = p.collateralETH;
        v.debtETH = p.debtETH;
        v.holdingTOKEN = p.holdingTOKEN;
        v.openedAtBlock = p.openedAtBlock;

        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId());
        v.currentValueEth = _tokenValueInEth(p.holdingTOKEN, sqrtP);
        v.healthBps = p.debtETH == 0
            ? type(uint256).max
            : (v.currentValueEth * 10_000) / p.debtETH;
        v.liquidatable = p.debtETH > 0 && v.healthBps < LIQUIDATION_HEALTH_BPS;

        // Pre-mainnet fix: derive liquidation price from CURRENT debt/holding
        // ratio (correct after partial closes), not from original leverage.
        //
        // Liquidation condition: tokenValue(holding, sqrtP_liq) = LIQ_BPS × debt / BPS
        // Curve identity:   tokenValue(holding, eth) = holding × (V+eth)² / (K × 1e18)
        // ⟹ (V + eth_liq)² = K × 1e18 × LIQ_BPS × debt / (BPS × holding)
        //
        // All values in wei. K is LDF.K (already 1e18-scaled). FullMath.mulDiv
        // avoids 256-bit overflow in the intermediate multiplication.
        if (p.debtETH > 0 && p.holdingTOKEN > 0) {
            uint256 vPlusEthSq = FullMath.mulDiv(
                LDF.K * 1e18,
                LIQUIDATION_HEALTH_BPS * p.debtETH,
                10_000 * p.holdingTOKEN
            );
            uint256 vPlusEth = LDF.sqrt(vPlusEthSq);
            v.liquidationEth = vPlusEth > LDF.VIRTUAL_ETH ? vPlusEth - LDF.VIRTUAL_ETH : 0;
        }
    }

    function getUserPositions(address user) external view returns (PositionView[] memory views) {
        uint256[] memory ids = userPositions[user];
        // L-01 fix: include positions where partial close fully repaid debt
        // but holding remains. User can still recover holding via close().
        uint256 openCount;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = _positions[ids[i]];
            if (p.debtETH > 0 || p.holdingTOKEN > 0) openCount++;
        }
        views = new PositionView[](openCount);
        uint256 j;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = _positions[ids[i]];
            if (p.debtETH > 0 || p.holdingTOKEN > 0) {
                views[j++] = getPosition(ids[i]);
            }
        }
    }

    /// @notice Length of a user's history. Pair with the auto-generated
    ///         `userHistory(addr, idx)` getter to page through records.
    function userHistoryLength(address user) external view returns (uint256) {
        return userHistory[user].length;
    }

    function openIdAt(uint256 i) external view returns (uint256) {
        return _openIds[i];
    }
}
