// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency, equals} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {GPX} from "./GPX.sol";
import {TokenFactory} from "../utils/TokenFactory.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {AmountHelpers2} from "../utils/AmountsHelper2.sol";
import {PositionInfoLibrary, PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {GPXOwner} from "../gpxowner/GPXOwner.sol";
import {GPOVault} from "../gpovault/GPOVault.sol";
import {Pawn} from "../pawn/Pawn.sol";
import {GoldPesaMines} from "../goldpesamines/GoldPesaMines.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * ______________________________________________________________________________ 
 * ┌────────────────────────────────────────────────────────────────────────────┐
 * │                                                                            │
 * │  GPX Liquidity Protocol — Uniswap V4 Hook Contract (GPX Hooks)             │
 * │                                                                            │
 * │  A fully decentralized and immutable contract powered by Uniswap V4.       │
 * │  100% trustless DeFi - No owner.                                           │
 * │                                                                            │
 * └────────────────────────────────────────────────────────────────────────────┘
 *
 * @notice Description:
 * - This contract is the central orchestrator for GoldPesa's Uniswap V4 integration. 
 * - It manages hook-based behaviors for the GPX-USDC pool, ensuring fee collection, liquidity minting, and automated pool rebalancing.
 * - This contract cannot be paused, modified, or censored — making it a permanent, permissionless tool for powering liquidity strategies without intermediaries.
 *
 * @notice Key Responsibilities:
 * ─────────────────────
 * 1. Pool Initialization & Deployment
 *  - Deploys the GPX token and GPXOwner contract
 *  - Initializes the Uniswap V4 GPX-USDC pool with a starting price.
 *
 * 2. Hook Enforcement
 *  - Implements Uniswap V4 hooks to enforce custom logic.
 *  - Blocks unauthorized pool initializations or liquidity manipulation.
 *  - Charges and distributes fees based on swap direction and token used.
 *
 * 3. Fee Collection & Distribution
 *  - Applies 1% total fees on every trade.
 *  - Fees are distributed to:
 *    - 0.25% - GoldPesa Mines (GPX)
 *    - 0.25% - GoldPesa Treasury (GPX)
 *    - 0.25% - Pawn Contract (USDC)
 *    - 0.25% - GPX Owner (USDC)
 *
 * 4. Liquidity Minting & Locking
 *  - Performs initial liquidity minting in `mintInitialLiquidity()` once.
 *  - Locks liquidity permanently after first mint to prevent future tampering.
 *
 * 5. Automated Rebalancing
 *  - Monitors market conditions and circulating GPX to determine when a rebalance is needed.
 *  - If triggered, rebalances the GPX-USDC pool by burning the old position and minting a new one.
 *
 * @notice Security & Design Considerations:
 * ────────────────────────────────
 * - Liquidity changes are only allowed during internal `reBalance()` routines.
 * - Only the contract may initialize the pool. External initialization attempts are rejected.
 * - ETH transfers to the contract are explicitly disabled.
 *
 * This contract serves as the backbone of the GPX trading ecosystem, automating a demand based release of supply,
 * fee distribution, and liquidity optimization while ensuring robust access control and seamless integration with Uniswap V4.
 */
 contract GPXHooks is BaseHook, TokenFactory {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for int128;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using AmountHelpers2 for IPoolManager;
    using SafeERC20 for IERC20;

    // =======================
    // ======= ERRORS ========
    // =======================

    /// @dev Thrown when a pool is initialized without proper authorization.
    error UnauthorizedPoolInitialization();
    /// @dev Thrown when liquidity is added from a source other than the Hook.
    error OnlyHookCanAddLiquidity();
    /// @dev Thrown when liquidity is removed from a source other than the Hook.
    error OnlyHookCanRemoveLiquidity();
    /// @dev Thrown when liquidity is permanently locked and cannot be modified.
    error LiquidityLockedForever();
    /// @dev Thrown when donation operations are attempted but are not permitted.
    error DonationsNotAllowed();
    /// @dev Reverts when the positionId is invalid based on pool or tick configuration.
    error InvalidPositionId();

    // =======================
    // ======= EVENTS ========
    // =======================

    /// @notice Emitted when GPX fees are distributed to the GoldPesa Mine and GPX Treasury.
    /// @param minesAddress GoldPesa Mines contract address receiving GPX fee share.
    /// @param feeToMines Amount of GPX fee sent to the GoldPesa Mine.
    /// @param treasuryAddress GPX Treasury contract address receiving GPX fee share.
    /// @param feeToTreasury Amount of GPX fee sent to the GPX Treasury.
    event gpxFeeDistributed(
        address indexed minesAddress,
        uint256 feeToMines,
        address indexed treasuryAddress,
        uint256 feeToTreasury
    );

    /// @notice Emitted when USDC fees are distributed to the Pawn and GPX Owner.
    /// @param pawnAddress Pawn contract address receiving USDC fee share.
    /// @param feeToPawn Amount of USDC fee sent to the Pawn.
    /// @param gpxOwnerAddress GPX Owner contract address receiving USDC fee share.
    /// @param feeToGPXOwner Amount of USDC fee sent to the GPX Owner.
    event usdcFeeDistributed(
        address indexed pawnAddress,
        uint256 feeToPawn,
        address indexed gpxOwnerAddress,
        uint256 feeToGPXOwner
    );

    /// @notice Emitted when token donations are detected and forwarded to the recipient
    /// @param tokenAddress The address of the token being donated.
    /// @param recipient The address receiving the donation.
    /// @param amount The amount of tokens donated and transferred.
    event ThankYouForYourDonations(
        address indexed tokenAddress,
        address indexed recipient, 
        uint256 amount
    );

    /// @notice Emitted before executing a simulated swap, logging the current pool and supply state
    /// @param usdcInsidePool The amount of USDC currently in the liquidity pool
    /// @param currentSqrtPriceX96 The current sqrt price (Q64.96 format) of the pool
    /// @param gpxCirculatingSupply The circulating supply of the GPX token at this moment
    event CurrentStateBeforeSimulation(
        uint256 usdcInsidePool, 
        uint160 currentSqrtPriceX96, 
        uint256 gpxCirculatingSupply
    );

    /// @notice Emitted after a swap to record the new tick
    /// @param currentLowerTick Current lower tick value of the pool
    /// @param currentTick Current tick value of the pool
    /// @param tickAfterSwap Tick value of the pool after swap
    event SimulatedTickValuesAfterSwap(
        int24 currentLowerTick,
        int24 currentTick, 
        int24 tickAfterSwap
    );

    /// @notice Emitted after a successful pool rebalance
    /// @param positionId ID of the new Uniswap V4 position
    /// @param lowerTick New lower tick for the liquidity position
    /// @param upperTick New upper tick for the liquidity position
    /// @param gpxDeposited Approximate GPX deposited into Uniswap after rebalance
    /// @param usdcDeposited Approximate USDC deposited into Uniswap after rebalance
    /// @param gpxRemaining Remaining GPX balance inside the hook contract after rebalance
    /// @param usdcRemaining Remaining USDC balance inside the hook contract after rebalance
    /// @param timestamp Timestamp when the rebalance was executed
    event Rebalanced(
        uint256 indexed positionId,   
        int24 lowerTick,              
        int24 upperTick,              
        uint256 gpxDeposited,         
        uint256 usdcDeposited,        
        uint256 gpxRemaining,         
        uint256 usdcRemaining,        
        uint256 timestamp            
    );

    // =================================
    // ========== CONSTANTS ============
    // =================================

    /// @notice Fee On Swap (%)
    uint256 public constant FEE_ON_SWAP_PERCENT = 1;
    /// @notice GPX Total Supply
    uint256 public constant GPX_TOTAL_SUPPLY = 100_000_000 * 10**18;
    /// @notice GPX Initial Supply
    uint256 public constant GPX_INITIAL_SUPPLY = 100_000 * 10**18;
    /// @dev No Hook Data
    bytes internal constant ZERO_BYTES = bytes("");
    /// @dev Starting Tick Price (1 GPX (1e18) = 1 USDC (1e6))
    int24 public constant startingTick = -276324;
    /// @dev Minimum spread between lower tick and current tick
    int24 public constant MIN_SPREAD = 9624;

    // =================================
    // ======= PUBLIC STATE GETTERS ====
    // =================================

    /// @notice Uniswap V4 IPoolManager defined in BaseHook as poolManager

    /// @notice Uniswap V4 Position Manager
    IPositionManager public immutable positionManager;
    /// @notice GPX Currency
    Currency public immutable gpx;
    /// @notice USDC Currency
    Currency public immutable usdc;
    /// @notice The Pawn Contract
    address public pawn;
    /// @notice GoldPesa Mines Treasury Contract
    address public mines;
    /// @notice GoldPesa Vault Contract
    address public vault;
    /// @notice GoldPesa Treasury Contract
    address public immutable treasury;
    /// @dev Permit2 address
    address public immutable permit2;
    /// @notice GPX Owner Contract
    GPXOwner public immutable gpxOwner;
    /// @notice Current Position ID
    uint256 public positionId;
    /// @notice GPX Pool Key
    PoolKey public gpxPoolKey;
    /// @notice Liquidity Locked Flag
    bool public liquidityLocked;
    /// @notice GPX Reserves
    uint256 public gpxReserves;
    /// @notice Last Rebalance timestamp (unix timestamp)
    uint256 public lastRebalance;
    /// @notice Current lower tick
    int24 public lowerTick;

    // =================================
    // ==== PRIVATE STATE VARIABLES ====
    // =================================

    /// @dev Flag which only allows the hook to rebalance liquidity
    bool private isRebalancing;
    /// @dev Address set flag to prevent multiple calls
    bool private addressesSet;
    /// @dev Deployer address, used for one-time setup operations
    address private immutable deployer;

    // =================================
    // ========== MODIFIERS ============
    // =================================

    /// @notice Liquidity Not Locked Modifier
    modifier liquidityNotLocked() {
        if (liquidityLocked) revert LiquidityLockedForever();
        _;
    }

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @dev Initializes the GPXHooks contract
     *
     * @param _poolManager Uniswap V4 Pool Manager address
     * @param _positionManager Uniswap V4 Position Manager address
     * @param _usdc USDC Token Address
     * @param _treasury GoldPesa Treasury address
     * @param _router Uniswap V4 Universal Router address
     * @param _multiSigWalletGPXOwner GPX Owner address
     * @param _permit2 Permit2 address
     * @param _deployer Deployer address for one-time setup operations
     *
     */
    constructor(
        address _poolManager,
        address _positionManager,
        address _usdc,
        address _treasury,
        address _router,
        address _multiSigWalletGPXOwner,
        address _permit2,
        address _deployer
    ) payable BaseHook(IPoolManager(_poolManager)) TokenFactory(_usdc) {
        // Set the deployer address for one-time setup operations
        deployer = _deployer;

        positionManager = IPositionManager(_positionManager);
        usdc = Currency.wrap(_usdc);
        treasury = _treasury;
        permit2 = _permit2;
        
        // Encode constructor arguments for GPX contract 
        bytes memory constructorArgs = abi.encode(
            _treasury,
            address(this),
            _router,
            _poolManager
        );

        // Get GPX bytecode and append constructor arguments
        bytes memory gpxBytecode = abi.encodePacked(
            type(GPX).creationCode,
            constructorArgs
        );

        // Deploy the GPX contract using deployToken0 ensuring gpx (currency0) < usdc (currency1)
        address _gpx = deployToken0(gpxBytecode);
        gpx = Currency.wrap(_gpx);

        // Check to make sure that GPX address is less than USDC
        require(_gpx < _usdc, "GPX address is not less than USDC address");

        // Ensure the contract holds the full GPX supply
        uint256 gpxTotalBalance = IERC20(_gpx).balanceOf(address(this));

        // Double check to make sure GPX's total supply is in this contract
        require(gpxTotalBalance == GPX_TOTAL_SUPPLY, "Total GPX supply is not available");

        // Set the gpx reserves to the total supply of GPX
        gpxReserves = gpxTotalBalance;

        // Deploy the GPX Owner contract
        gpxOwner = new GPXOwner(_multiSigWalletGPXOwner);

        // Configure the GPX Pool
        gpxPoolKey = PoolKey({
            currency0: gpx,
            currency1: usdc,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(this))
        });

        // Initializes the pool with the given initial square root price
        poolManager.initialize(gpxPoolKey, TickMath.getSqrtPriceAtTick(startingTick));
    }

    // ============================
    // ======= MAIN FUNCTION ======
    // ============================

    /**
     * @notice Mints the initial GPX liquidity into the Uniswap V4 pool.
     * - This function can only be called once and requires that all GPX supply is held by this contract. 
     * - It permanently locks the liquidity after minting.
     *
     * @custom:warning This function assumes that the full GPX total supply is available within the contract and will revert if not.
     * @custom:security Only call this once during setup; subsequent calls will revert.
     */
    function mintInitialLiquidity() external liquidityNotLocked {
        require(msg.sender == deployer, "Only deployer can mint initial liquidity");

        // 1. Ensure the contract holds the full GPX supply
        uint256 gpxTotalBalance = IERC20(Currency.unwrap(gpx)).balanceOf(address(this));

        // 2. Safety check to make sure GPX's total supply is in this contract
        require(gpxTotalBalance == GPX_TOTAL_SUPPLY, "Total GPX supply is not available");

        // 3. Calculate the initial liquidity based on the GPX initial supply
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(startingTick),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            GPX_INITIAL_SUPPLY
        );

        // 4. Prepare action sequence: MINT_POSITION → SETTLE_PAIR
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        // 5. Prepare Action parameters
        bytes[] memory params = new bytes[](2);

        // 6. Encode MINT_POSITION parameters
        params[0] = abi.encode(
            gpxPoolKey,
            startingTick,
            TickMath.MAX_TICK,
            liquidity,
            GPX_INITIAL_SUPPLY,
            0, // no USDC amount
            address(this),
            ZERO_BYTES
        );

        // 7. Encode SETTLE_PAIR parameters
        params[1] = abi.encode(
            gpxPoolKey.currency0, 
            gpxPoolKey.currency1
        );

        // 8. Approve token transfers via Permit2 and PositionManager
        IERC20(Currency.unwrap(gpx)).approve(permit2, GPX_INITIAL_SUPPLY);
        IAllowanceTransfer(permit2).approve(
            Currency.unwrap(gpx),
            address(positionManager),
            GPX_INITIAL_SUPPLY.toUint160(),
            type(uint48).max
        );

        // 9. Execute the multicall to mint and settle the liquidity
        uint256 deadline = block.timestamp + 300;
        isRebalancing = true;
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            deadline
        );
        isRebalancing = false;

        // 10. Store the position ID
        positionId = positionManager.nextTokenId() - 1;

        // 11. Liquidity is locked forever after initial mint
        liquidityLocked = true;

        // 12. Set the gpx reserves to the total remaining supply of GPX after minting initial liquidity
        gpxReserves = IERC20(Currency.unwrap(gpx)).balanceOf(address(this));

        // 13. Set lastRebalance timestamp to the current block timestamp
        lastRebalance = block.timestamp;

        // 14. Set the current lower tick to the starting tick
        lowerTick = startingTick;

        // 15. Validate the position ID
        if (!checkPositionId()) {
            revert InvalidPositionId();
        }
    }

    /**
     * @dev Safety check to ensure that the positionId is set and valid.
     *
     * @return bool True if the positionId is valid, false otherwise.
     */
    function checkPositionId() internal view returns (bool) {
        // Obtain the PoolKey and PositionInfo from the PositionManager
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(positionId);

        // Perform individual checks and assign to booleans
        bool isCurrency0Correct = poolKey.currency0 == gpx;
        bool isCurrency1Correct = poolKey.currency1 == usdc;
        bool isFeeCorrect = poolKey.fee == 0;
        bool isTickSpacingCorrect = poolKey.tickSpacing == 1;
        bool isHookCorrect = address(poolKey.hooks) == address(this);

        bool isTickLowerCorrect = info.tickLower() == lowerTick;
        bool isTickUpperCorrect = info.tickUpper() == TickMath.MAX_TICK;

        // Return true only if all checks pass
        return (
            isCurrency0Correct &&
            isCurrency1Correct &&
            isFeeCorrect &&
            isTickSpacingCorrect &&
            isHookCorrect &&
            isTickLowerCorrect &&
            isTickUpperCorrect
        );
    }

    /**
     * Defines the Uniswap V4 hooks utilized in our implementation, specifying the exact address where our contract
     * must be deployed for Uniswap V4 compatibility.
     *
     * @dev 0010 1010 1010 1000 == 2AA8
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: true,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * This hook is triggered before a pool's state is initialized, ensuring that external contracts
     * cannot initialize pools using our contract as a hook.
     *
     * @dev Since `poolManager.initialize` is called directly from the constructor, this hook
     * is bypassed, effectively circumventing the restriction.
     */
    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external view override onlyPoolManager returns (bytes4) {
        revert UnauthorizedPoolInitialization();
    }

    /// @inheritdoc IHooks
    /// @dev Restricts liquidity additions to internal rebalancing only.
    ///      Reverts unless `isRebalancing` is true, preventing any external or unauthorized mints.
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (!isRebalancing) revert OnlyHookCanAddLiquidity();
        return this.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Restricts liquidity removal to internal rebalancing operations only.
    ///      Reverts unless `isRebalancing` is true, preventing any external or unauthorized burns.
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (!isRebalancing) revert OnlyHookCanRemoveLiquidity();
        return this.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Disable all external donations
    function beforeDonate(
        address, 
        PoolKey calldata, 
        uint256, uint256, 
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        revert DonationsNotAllowed();
    }

    /**
     * @notice Hook executed before each swap in the GPX liquidity pool.
     *
     * @param key The PoolKey representing the Uniswap V4 pool involved in the swap.
     * @param params Swap parameters including direction and amount specified.
     *
     * @return selector The function selector for `beforeSwap`.
     * @return returnDelta The amount of fee to deduct from the pool in the specified and unspecified currencies.
     * @return hookData A reserved uint24 value (unused, set to 0).
     */
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // Check for their donations
        checkForDonations();

        // Prevent re-execution within the same hour
        if (block.timestamp - lastRebalance >= 1 hours) {
            reBalanceRoutine();
        }
       
        // Determine swap type: true = exact input, false = exact output
        bool exactInput = params.amountSpecified < 0;

        // Identify which token is specified in beforeSwap
        Currency beforeSwapSpecifiedCurrency = exactInput == params.zeroForOne
            ? key.currency0 // GPX
            : key.currency1; // USDC

        ( ,, uint256 feeSpecified, uint256 feeUnspecified) = AmountHelpers2
            .computeSwapFeeAmounts(
                poolManager,
                params,
                key
            );

        // Fetch the current balances of GPX and USDC in the poolManager
        uint256 gpxPoolBalance = IERC20(Currency.unwrap(gpx)).balanceOf(address(poolManager));
        uint256 usdcPoolBalance = IERC20(Currency.unwrap(usdc)).balanceOf(address(poolManager));
        
        // Total fee amounts collected in specified and unspecified currencies
        uint256 totalSpecifiedFeeCollected = 0;
        uint256 totalUnspecifiedFeeCollected = 0;

        // Calculate the half percent fee to be distributed in GPX
        uint256 gpxHalfPercent = beforeSwapSpecifiedCurrency == gpx 
                ? feeSpecified / 2 // 0.50% of the specified GPX amount
                : feeUnspecified / 2; // 0.50% of the unspecified GPX amount

        // Calculate the half percent fee to be distributed in USDC
        uint256 usdcHalfPercent = beforeSwapSpecifiedCurrency == usdc
                ? feeSpecified / 2 // 0.50% of the specified USDC amount
                : feeUnspecified / 2; // 0.50% of the unspecified USDC amount

        // Take the fee in GPX from poolManager and distribute to the GoldPesa Mines and Treasury
        if (gpxPoolBalance >= gpxHalfPercent) {
            // Calculate the quarter percent fee (0.25%) in GPX
            uint256 gpxQuarterPercent = gpxHalfPercent / 2; 

            // Distribute 0.25% fee in GPX to GoldPesa Mines
            gpx.take(poolManager, mines, gpxQuarterPercent, false);
            // Distribute 0.25% fee in GPX to the Treasury (only GPXHook is authorized to transfer GPX to treasury)
            gpx.take(poolManager, address(this), gpxQuarterPercent, false);
            IERC20(Currency.unwrap(gpx)).safeTransfer(treasury, gpxQuarterPercent);

            if (beforeSwapSpecifiedCurrency == gpx) {
                // Increment total specified fee collected in GPX
                totalSpecifiedFeeCollected += gpxQuarterPercent + gpxQuarterPercent;
            } else {
                // Increment total unspecified fee collected in GPX
                totalUnspecifiedFeeCollected += gpxQuarterPercent + gpxQuarterPercent;
            }

            // Emit GPX Fee Distributed event
            emit gpxFeeDistributed(mines, gpxQuarterPercent, treasury, gpxQuarterPercent);
        }

        // Take the fee in USDC from poolManager and distribute to the Pawn and GPX Owner
        if (usdcPoolBalance >= usdcHalfPercent) {
             // Calculate the quarter percent fee (0.25%) in USDC
            uint256 usdcQuarterPercent = usdcHalfPercent / 2; 
            
            // Distribute 0.25% fee in USDC to Pawn
            usdc.take(poolManager, pawn, usdcQuarterPercent, false);
            // Distribute 0.25% fee in USDC to GPX owner
            usdc.take(poolManager, gpxOwner.owner(), usdcQuarterPercent, false);

            if (beforeSwapSpecifiedCurrency == usdc) {
                // Increment total specified fee collected in USDC
                totalSpecifiedFeeCollected += usdcQuarterPercent + usdcQuarterPercent;
            } else {
                // Increment total unspecified fee collected in USDC
                totalUnspecifiedFeeCollected += usdcQuarterPercent + usdcQuarterPercent;
            }

            // Emit USDC Fee Distributed event
            emit usdcFeeDistributed(pawn, usdcQuarterPercent, gpxOwner.owner(), usdcQuarterPercent);
        }

        // Prepare the return delta for the beforeSwap hook
        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            totalSpecifiedFeeCollected.toInt128(), 
            totalUnspecifiedFeeCollected.toInt128()
        );

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    /**
     * @notice Detects and transfers any unsolicited GPX token donations to the GPX owner.
     * @dev Compares the contract's current GPX balance with the recorded `gpxReserves`.
     * - If the balance exceeds reserves, the surplus is considered a donation.
     * - The donation is then transferred to the GPX owner and a gratitude event is emitted.
     */
    function checkForDonations() internal {
        // GPX Token Address
        address gpxTokenAddress = Currency.unwrap(gpx);
        // Check the current GPX balance in the contract
        uint256 gpxBalance = IERC20(gpxTokenAddress).balanceOf(address(this));
        // If the balance is greater than GPX Reserves, we can thank the donors
        if (gpxBalance > gpxReserves) {
            // Calculate GPX donation amount
            uint256 gpxDonation = gpxBalance - gpxReserves;
            // Get the GPX Owner
            address gpxOwnerAddress = gpxOwner.owner();
            // Transfer donations to GPX Owner
            IERC20(gpxTokenAddress).safeTransfer(gpxOwnerAddress, gpxDonation);
            // Emit a thank you event
            emit ThankYouForYourDonations(gpxTokenAddress, gpxOwnerAddress, gpxDonation);
        }
    }

    /**
     * @notice Entry point to trigger the GPX liquidity pool rebalance routine.
     */
    function reBalanceRoutine() internal {
        // Perform rebalance check
        (
            bool rebalance,
            int24 newLowerTick,
            uint256 gpxInsideUniswap,
            uint256 usdcInsideUniswap,
            uint160 sqrtPriceCurrentX96
        ) = checkRebalance(gpxPoolKey);

        // Rebalance only if check passed
        if (rebalance) {
            reBalance(
                gpxPoolKey,
                newLowerTick,
                gpxInsideUniswap,
                usdcInsideUniswap,
                sqrtPriceCurrentX96
            );
        }
    }
    
    /**
     * @notice Determines whether a GPX liquidity rebalance is needed based on 
     *         circulating supply, current pool state, and projected post-swap tick.
     *
     * @param key The PoolKey representing the Uniswap V4 pool to check.
     *
     * @return rebalance True if a rebalance should be performed.
     * @return newLowerTick The recommended new lower tick after simulated dump.
     * @return gpxInUniswap Approximate GPX currently deployed in the pool.
     * @return usdcInUniswap Approximate USDC currently deployed in the pool.
     * @return currentSqrtPriceX96 The current square root price of the pool (X96 format).
     *
     */
    function checkRebalance(PoolKey memory key)
        internal
        returns (
            bool rebalance,
            int24 newLowerTick,
            uint256 gpxInUniswap,
            uint256 usdcInUniswap,
            uint160 currentSqrtPriceX96
        )
    {
        // 1. Get circulating supply and pool balances
        (uint256 gpxCirculatingSupply, uint256 gpxInsidePool, uint256 usdcInsidePool) = getCurrentState(key);

        // 2. Return false if there's no GPX in circulation or USDC in the pool
        if (gpxCirculatingSupply == 0 || usdcInsidePool == 0) return (false, 0, 0, 0, 0);

        // 3. Get current tick info
        PositionInfo currentPosition = positionManager.positionInfo(positionId);
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(id);
        int24 currentLowerTick = currentPosition.tickLower();

        emit CurrentStateBeforeSimulation(usdcInsidePool, sqrtPriceX96, gpxCirculatingSupply);

        // 4. Calculate the new square root price after the swap
        uint256 aX96 = FullMath.mulDiv(usdcInsidePool << 192, 1, gpxCirculatingSupply * sqrtPriceX96);

        // 5. Convert the new square root price into the corresponding tick
        int24 simulatedTick = TickMath.getTickAtSqrtPrice(aX96.toUint160());

        emit SimulatedTickValuesAfterSwap(currentLowerTick, currentTick, simulatedTick);

        // 6. Safety Boundry Check
        if (simulatedTick <= currentLowerTick || simulatedTick >= currentTick) {
            return (false, 0, 0, 0, 0);
        }

        // 7. Cap floor increase to +1 tick per rebalance
        int24 proposedLowerTick = currentLowerTick + 1;
        if (proposedLowerTick + MIN_SPREAD > currentTick) return (false, 0, 0, 0, 0);

        // 8. Simulate whether we have enough GPX for this range
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(proposedLowerTick);
        bool hasEnough = enoughGPX(sqrtPriceAX96, gpxInsidePool, usdcInsidePool, sqrtPriceX96);
        if (!hasEnough) return (false, 0, 0, 0, 0);

        return (true, proposedLowerTick, gpxInsidePool, usdcInsidePool, sqrtPriceX96);
    }


    /**
     * @notice Fetches the current state of GPX and USDC relevant to Uniswap V4 liquidity and circulation.
     *
     * @param key The PoolKey for the Uniswap V4 pool.
     *
     * @return gpxCirculatingSupply The GPX circulating supply (excludes treasury, reserves, and Uniswap LP).
     * @return gpxInsideUniswap The approximate amount of GPX deployed in the Uniswap V4 pool.
     * @return usdcInsideUniswap The approximate amount of USDC deployed in the Uniswap V4 pool.
     */
    function getCurrentState(
        PoolKey memory key
    )
        internal
        view
        returns (
            uint256 gpxCirculatingSupply,
            uint256 gpxInsideUniswap,
            uint256 usdcInsideUniswap
        )
    {
        // 1. Fetch total GPX token supply
        uint256 totalGPXSupply = IERC20(Currency.unwrap(gpx)).totalSupply();

        // 2. Fetch GPX reserves (GPX held in this contract)
        uint256 currentGPXReserves = gpxReserves;

        // 3. Fetch GPX held in GPX Treasury (not circulating)
        uint256 gpxInsideTreasury = IERC20(Currency.unwrap(gpx)).balanceOf(treasury);

        // 4. Get active position info
        PositionInfo currentPosition = positionManager.positionInfo(positionId);

        // 5. Estimate token amounts deployed in Uniswap V4 LP (approximate)
        (gpxInsideUniswap, usdcInsideUniswap) = poolManager.getMaxAmountInForPool2(
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentPosition.tickLower(),
                tickUpper: currentPosition.tickUpper(),
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            key
        );

        // 6. Calculate GPX circulating supply (Total - Reserves - Liquidity - Treasury)
        gpxCirculatingSupply = totalGPXSupply - currentGPXReserves - gpxInsideUniswap - gpxInsideTreasury;
    }

    /**
     * @notice Checks whether the contract has enough GPX (on-hand + in Uniswap) 
     *         to rebalance the pool for a new liquidity range.
     *
     * @param sqrtPriceAX96 The square root price at the proposed new lower tick.
     * @param gpxInsideUniswap The amount of GPX currently deployed in the Uniswap position.
     * @param usdcInsideUniswap The amount of USDC currently deployed in the Uniswap position.
     * @param currentSqrtPriceX96 The current square root price of the Uniswap pool.
     *
     * @return hasEnoughGPX Boolean indicating if the contract has sufficient GPX to rebalance.
     */
    function enoughGPX(
        uint160 sqrtPriceAX96,
        uint256 gpxInsideUniswap,
        uint256 usdcInsideUniswap,
        uint160 currentSqrtPriceX96
    ) internal view returns (bool hasEnoughGPX) {
        // Calculate the liquidity for the proposed USDC amount over the new range
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            sqrtPriceAX96,
            currentSqrtPriceX96,
            usdcInsideUniswap
        );

        // Determine how much GPX is needed to support this liquidity
        uint256 gpxNeeded = LiquidityAmounts.getAmount0ForLiquidity(
            currentSqrtPriceX96,
            TickMath.MAX_SQRT_PRICE,
            liquidity
        );

        // Sum GPX available in the hook contract and already deployed in Uniswap
        uint256 totalGPXAvailable = gpxReserves + gpxInsideUniswap;

        hasEnoughGPX = gpxNeeded <= totalGPXAvailable;
    }

    /**
     * @notice Rebalances the Uniswap V4 pool by burning the current position, 
     *         settling and taking tokens, and minting a new position based on updated tick bounds.
     *         
     * @param key Pool key structure containing currencies, fee, spacing, and hooks.
     * @param newLowerTick The new lower tick for the next position.
     * @param gpxInsideUniswap Amount of GPX liquidity to burn.
     * @param usdcInsideUniswap Amount of USDC liquidity to burn.
     * @param sqrtPriceCurrentX96 Current square root price of the pool.
     */
    function reBalance(
        PoolKey memory key,
        int24 newLowerTick,
        uint256 gpxInsideUniswap,
        uint256 usdcInsideUniswap,
        uint160 sqrtPriceCurrentX96
    ) internal {
        // Add 1% cushion for minimum GPX and USDC expected when burning
        uint256 minGPXExpected = gpxInsideUniswap * 99 / 100; // 1% less GPX
        uint256 minUSDCExpected = usdcInsideUniswap * 99 / 100; // 1% less USDC

        // Step 1: Burn the current position and take the tokens back to the hook
        bytes memory burnActions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory burnParams = new bytes[](2);
        // Encode the BURN_POSITION parameters
        burnParams[0] = abi.encode(
            positionId,
            minGPXExpected.toUint128(),
            minUSDCExpected.toUint128(),
            ZERO_BYTES
        );

        // Encode the TAKE_PAIR parameters
        burnParams[1] = abi.encode(
            key.currency0,
            key.currency1,
            address(this)
        );

        isRebalancing = true;
        positionManager.modifyLiquiditiesWithoutUnlock(
            burnActions, 
            burnParams
        );
        isRebalancing = false;

        // Step 2: Determine new liquidity based on USDC inside hook contract
        uint256 usdcInsideHook = IERC20(Currency.unwrap(usdc)).balanceOf(address(this));

        // USDC Donation Check
        if (usdcInsideHook > usdcInsideUniswap) {
            // Calculate the USDC donation amount
            uint256 usdcDonation = usdcInsideHook - usdcInsideUniswap;
            // Get the GPX Owner address
            address gpxOwnerAddress = gpxOwner.owner();
            // Transfer USDC donations to the GPX Owner
            IERC20(Currency.unwrap(usdc)).safeTransfer(gpxOwnerAddress, usdcDonation);
            // Set the USDC inside hook to the original amount in Uniswap
            usdcInsideHook = usdcInsideUniswap;
            // Emit a Thank You event
            emit ThankYouForYourDonations(Currency.unwrap(usdc), gpxOwnerAddress, usdcDonation);
        }

        // Calculate the new liquidity for the new lower tick given the USDC inside hook
        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(newLowerTick),
            sqrtPriceCurrentX96,
            usdcInsideHook
        );

        // Determine how many GPX (currency0) we will need to rebalance the pool with newliquidity
        uint256 gpxRequired = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtPriceCurrentX96,
            TickMath.MAX_SQRT_PRICE,
            newLiquidity
        );

        // Add a 1% buffer to avoid rounding issues
        uint256 maxGPXSpend = (gpxRequired * 101) / 100;
        uint256 maxUSDCSpend = (usdcInsideHook * 101) / 100;

        // Step 3: Mint new liquidity position and settle owed tokens
        bytes memory mintActions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory mintParams = new bytes[](2);

        // Encode the MINT_POSITION parameters
        mintParams[0] = abi.encode(
            key,
            newLowerTick,
            TickMath.MAX_TICK,
            newLiquidity,
            maxGPXSpend,
            maxUSDCSpend,
            address(this),
            ZERO_BYTES
        );

        // Encode the SETTLE_PAIR parameters
        mintParams[1] = abi.encode(
            key.currency0,
            key.currency1
        );

        // Approve GPX and USDC via Permit2 for use by PositionManager
        IERC20(Currency.unwrap(gpx)).approve(permit2, maxGPXSpend);
        IAllowanceTransfer(permit2).approve(
            Currency.unwrap(gpx),
            address(positionManager),
            maxGPXSpend.toUint160(),
            type(uint48).max
        );

        IERC20(Currency.unwrap(usdc)).approve(permit2, maxUSDCSpend);
        IAllowanceTransfer(permit2).approve(
            Currency.unwrap(usdc),
            address(positionManager),
            maxUSDCSpend.toUint160(),
            type(uint48).max
        );

        isRebalancing = true;
        positionManager.modifyLiquiditiesWithoutUnlock(
            mintActions, 
            mintParams
        );
        isRebalancing = false;

        // Update to the new position ID
        positionId = positionManager.nextTokenId() - 1;

        // Set the gpx reserves to the total remaining supply of GPX after rebalancing
        gpxReserves = IERC20(Currency.unwrap(gpx)).balanceOf(address(this));

        // Set lastRebalance to the current block timestamp
        lastRebalance = block.timestamp;

        // Set the lower tick to the new lower tick after rebalance
        lowerTick = newLowerTick;

        // Validate the position ID
        if (!checkPositionId()) {
            revert InvalidPositionId();
        }

        // Emit the Rebalanced event with new position details
        emit Rebalanced(
            positionId, // New Position ID
            newLowerTick, // New Lower Tick
            TickMath.MAX_TICK, // New Upper Tick
            gpxRequired, // Approx GPX Inside Uniswap after Rebalance
            usdcInsideHook, // Approx USDC Inside Uniswap after Rebalance
            gpxReserves, // GPX Reserves inside hook after Rebalance
            IERC20(Currency.unwrap(usdc)).balanceOf(address(this)), // USDC Reserves inside hook after Rebalance
            lastRebalance // Last Rebalance Timestamp
        );
    }

    // ============================
    // ======= ETH GUARD ==========
    // ============================
    
    /**
     * @dev Fallback function to ensure ETH is never accepted.
     */
    receive() external payable {
        revert("ETH not accepted");
    }

    /**
     * @dev Fallback function to ensure ETH with data is never accepted.
     */
    fallback() external payable {
        revert("ETH not accepted");
    }

    // =============================
    // ======= ONE TIME SET ========
    // =============================

    /**
     * @dev Sets the addresses for the Pawn, Mines, and Vault contracts.
     * - Can only be called once by the authorized deployer to prevent unauthorized modifications.
     * - The addresses must not have been set previously.
     *
     * @param _pawn Address of the Pawn contract.
     * @param _mines Address of the Mines contract.
     * @param _vault Address of the Vault contract.
     */
    function setAddresses(address _pawn, address _mines, address _vault) external {
        require(msg.sender == deployer, "Only deployer can set addresses");
        require(!addressesSet, "Addresses already set");

        // Set the addresses for Pawn, Mines, and Vault
        pawn = _pawn;
        mines = _mines;
        vault = _vault;

        // Set the addresses in the GPX contract
        GPX gpxToken = GPX(Currency.unwrap(gpx));
        gpxToken.setAddresses(pawn, mines, vault);

        addressesSet = true;
    }
}
