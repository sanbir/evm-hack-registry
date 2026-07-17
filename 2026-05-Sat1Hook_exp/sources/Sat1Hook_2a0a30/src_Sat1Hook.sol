// SPDX-License-Identifier: MIT
// https://www.sat1.io/
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {Sat1Token} from "./Sat1Token.sol";
import {Curve} from "./lib/Curve.sol";

/// @title Sat1Hook
/// @notice SATO-style Uniswap V4 hook with a single curve state and auto-compounding fees.
contract Sat1Hook is IHooks {
    // ---- locked parameters -------------------------------------------------

    /// @notice Asymptotic supply cap of the curve.
    uint256 public constant K_SUPPLY = 21_000_000e18;

    /// @notice Curve scale. Calibrated so 99% of the curve is reached at about 1361 ETH.
    uint256 public constant S = 295_537_394_935_162_868_716;

    /// @notice Maximum ETH input on a single buy. Kept identical to SATO.
    uint256 public constant MAX_BUY_WEI = 5 ether;

    /// @notice Number of blocks of cooldown between a wallet's last buy and its first sell.
    uint256 public constant COOLDOWN_BLOCKS = 1;

    /// @notice Pool fee in V4 hundredths-of-bips (3000 = 0.3%).
    uint24 public constant POOL_FEE = 3000;

    /// @notice Number of blocks during which buys receive an entropy multiplier.
    uint256 public constant ENTROPY_BLOCKS = 100;

    /// @notice Numerator of the self-deprecation threshold (99/100 of K_SUPPLY).
    uint256 public constant EXHAUSTION_THRESHOLD_NUMERATOR = 99;

    /// @notice Denominator of the self-deprecation threshold.
    uint256 public constant EXHAUSTION_THRESHOLD_DENOMINATOR = 100;

    /// @notice Fee numerator (30 / 10000 = 0.3%).
    uint256 internal constant FEE_NUMERATOR = 30;
    uint256 internal constant FEE_DENOMINATOR = 10000;

    // ---- immutables --------------------------------------------------------

    IPoolManager public immutable POOL_MANAGER;
    Sat1Token public immutable SAT1_TOKEN;
    Currency public immutable ETH_CURRENCY;
    Currency public immutable SAT1_CURRENCY;
    uint256 public immutable GENESIS_BLOCK;
    bytes32 public immutable GENESIS_HASH;

    // ---- storage -----------------------------------------------------------

    bytes32[8] private _GENESIS_MESSAGE;

    /// @notice The single canonical curve state. Fees compound into this value.
    uint256 public ethCum;

    /// @notice Whether the curve has irreversibly entered self-deprecation. After this, no more buys.
    bool public selfDeprecated;

    /// @notice Whether the pool has been initialized.
    bool public poolInitialized;

    /// @notice The block of each address's last buy.
    mapping(address account => uint256 blockNumber) public lastBuyBlock;

    // ---- errors ------------------------------------------------------------

    error NotPoolManager();
    error InvalidPool();
    error LiquidityAdditionsForbidden();
    error BuyTooLarge();
    error CooldownActive();
    error SelfDeprecatedNoBuys();
    error ExactOutputUnsupported();
    error MissingSwapperInHookData();
    error InsufficientEthReserves();

    constructor(IPoolManager poolManager, Sat1Token sat1Token, bytes32[8] memory manifesto) {
        POOL_MANAGER = poolManager;
        SAT1_TOKEN = sat1Token;
        ETH_CURRENCY = Currency.wrap(address(0));
        SAT1_CURRENCY = Currency.wrap(address(sat1Token));
        GENESIS_BLOCK = block.number;
        GENESIS_HASH = blockhash(block.number - 1);

        for (uint256 i = 0; i < 8; ++i) {
            _GENESIS_MESSAGE[i] = manifesto[i];
        }

        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---- view --------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice SATO-compatible fair supply view, derived from the single `ethCum` state.
    function totalMintedFair() external view returns (uint256) {
        return Curve.totalMinted(ethCum);
    }

    /// @notice The ETH backing the curve. Direct ETH donations are deliberately not counted.
    function curveReserveEth() external view returns (uint256) {
        return ethCum;
    }

    function marginalPrice() external view returns (uint256) {
        return Curve.marginalPrice(ethCum);
    }

    function philosophy() external view returns (string memory) {
        bytes memory raw = new bytes(256);
        for (uint256 i = 0; i < 8; ++i) {
            bytes32 word = _GENESIS_MESSAGE[i];
            for (uint256 j = 0; j < 32; ++j) {
                raw[i * 32 + j] = word[j];
            }
        }

        uint256 len = 256;
        while (len > 0 && raw[len - 1] == 0x00) {
            unchecked {
                --len;
            }
        }

        bytes memory trimmed = new bytes(len);
        for (uint256 k = 0; k < len; ++k) {
            trimmed[k] = raw[k];
        }
        return string(trimmed);
    }

    // ---- modifiers ---------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    // ---- v4 hook entrypoints ----------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (Currency.unwrap(key.currency0) != address(0)) revert InvalidPool();
        if (Currency.unwrap(key.currency1) != address(SAT1_TOKEN)) revert InvalidPool();
        if (key.fee != POOL_FEE) revert InvalidPool();
        if (address(key.hooks) != address(this)) revert InvalidPool();

        poolInitialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityAdditionsForbidden();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride)
    {
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(SAT1_TOKEN)) {
            revert InvalidPool();
        }
        if (hookData.length < 32) revert MissingSwapperInHookData();

        address swapper = abi.decode(hookData, (address));
        if (params.zeroForOne) {
            return _executeBuy(uint256(-params.amountSpecified), swapper);
        } else {
            return _executeSell(uint256(-params.amountSpecified), swapper);
        }
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // ---- internal buy/sell -------------------------------------------------

    function _executeBuy(uint256 ethIn, address swapper) internal returns (bytes4, BeforeSwapDelta, uint24) {
        if (ethIn > MAX_BUY_WEI) revert BuyTooLarge();
        if (selfDeprecated) revert SelfDeprecatedNoBuys();

        uint256 fee = (ethIn * FEE_NUMERATOR) / FEE_DENOMINATOR;
        uint256 ethToMint = ethIn - fee;

        uint256 fairSat1 = Curve.mintFor(ethCum, ethToMint);
        uint256 mintAmount = _applyEntropy(fairSat1, swapper, ethIn);

        POOL_MANAGER.sync(SAT1_CURRENCY);
        SAT1_TOKEN.mint(address(POOL_MANAGER), mintAmount);
        POOL_MANAGER.settle();

        POOL_MANAGER.take(ETH_CURRENCY, address(this), ethIn);

        // C-plan: the full input, including fee, compounds into the curve reserve.
        ethCum += ethIn;
        lastBuyBlock[swapper] = block.number;

        if (Curve.totalMinted(ethCum) * EXHAUSTION_THRESHOLD_DENOMINATOR >= K_SUPPLY * EXHAUSTION_THRESHOLD_NUMERATOR) {
            selfDeprecated = true;
        }

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(ethIn)), -int128(int256(mintAmount)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function _executeSell(uint256 sat1In, address swapper) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 lastBlock = lastBuyBlock[swapper];
        if (lastBlock != 0 && (block.number - lastBlock) < COOLDOWN_BLOCKS) revert CooldownActive();

        uint256 actualSupply = SAT1_TOKEN.totalSupply();
        uint256 currentFairSupply = Curve.totalMinted(ethCum);
        uint256 sat1FairIn = (sat1In * currentFairSupply) / actualSupply;
        if (sat1FairIn > currentFairSupply) sat1FairIn = currentFairSupply;

        uint256 ethRaw = Curve.burnFor(currentFairSupply, sat1FairIn);
        uint256 fee = (ethRaw * FEE_NUMERATOR) / FEE_DENOMINATOR;
        uint256 ethOut = ethRaw - fee;

        if (ethOut > ethCum || address(this).balance < ethOut) revert InsufficientEthReserves();

        POOL_MANAGER.take(SAT1_CURRENCY, address(this), sat1In);
        SAT1_TOKEN.burn(address(this), sat1In);

        POOL_MANAGER.settle{value: ethOut}();

        // C-plan: only ETH actually paid out leaves the curve. The sell fee remains in `ethCum`.
        ethCum -= ethOut;

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(sat1In)), -int128(int256(ethOut)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function _applyEntropy(uint256 fairSat1, address swapper, uint256 ethIn) internal view returns (uint256) {
        if (block.number >= GENESIS_BLOCK + ENTROPY_BLOCKS) return fairSat1;
        bytes32 h = keccak256(abi.encodePacked(blockhash(block.number - 1), swapper, ethIn));
        uint256 mul = 9000 + (uint256(h) % 2001); // 9000..11000, in 1e-4 units.
        return (fairSat1 * mul) / 10000;
    }

    receive() external payable {}
}
