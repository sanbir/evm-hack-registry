pragma solidity 0.8.26;

import {LiquidityMath} from "./LiquidityMath.sol";
import {LiquidityToken} from "./../LiquidityToken.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IErrors} from "./../interfaces/IErrors.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransferHelper} from "Depeg-swap/contracts/libraries/TransferHelper.sol";

/// @notice amm id,
type AmmId is bytes32;

function toAmmId(address ra, address ct) pure returns (AmmId) {
    (address token0, address token1) = sort(ra, ct);

    return AmmId.wrap(keccak256(abi.encodePacked(token0, token1)));
}

function toAmmId(Currency _ra, Currency _ct) pure returns (AmmId) {
    (address ra, address ct) = (Currency.unwrap(_ra), Currency.unwrap(_ct));

    return toAmmId(ra, ct);
}

struct SortResult {
    address token0;
    address token1;
    uint256 amount0;
    uint256 amount1;
}

function sort(address a, address b) pure returns (address, address) {
    return a < b ? (a, b) : (b, a);
}

function reverseSortWithAmount(address a, address b, address token0, address token1, uint256 amount0, uint256 amount1)
    pure
    returns (address, address, uint256, uint256)
{
    if (a == token0 && b == token1) {
        return (token0, token1, amount0, amount1);
    } else if (a == token1 && b == token0) {
        return (token1, token0, amount1, amount0);
    } else {
        revert IErrors.InvalidToken();
    }
}

function sort(address a, address b, uint256 amountA, uint256 amountB)
    pure
    returns (address, address, uint256, uint256)
{
    return a < b ? (a, b, amountA, amountB) : (b, a, amountB, amountA);
}

function sortPacked(address a, address b, uint256 amountA, uint256 amountB) pure returns (SortResult memory) {
    (address token0, address token1, uint256 amount0, uint256 amount1) = sort(a, b, amountA, amountB);

    return SortResult(token0, token1, amount0, amount1);
}

function sortPacked(address a, address b) pure returns (SortResult memory) {
    (address token0, address token1) = sort(a, b);

    return SortResult(token0, token1, 0, 0);
}

/// @notice settle tokens from the pool manager, all numbers are fixed point 18 decimals on the hook
/// so this function is expected to be used on every "settle" action
function settleNormalized(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) {
    amount = TransferHelper.fixedToTokenNativeDecimals(amount, Currency.unwrap(currency));
    CurrencySettler.settle(currency, manager, payer, amount, burn);
}

function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) {
    CurrencySettler.settle(currency, manager, payer, amount, burn);
}

/// @notice take tokens from the pool manager, all numbers are fixed point 18 decimals on the hook
/// so this function is expected to be used on every "take" action
function takeNormalized(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) {
    amount = TransferHelper.fixedToTokenNativeDecimals(amount, Currency.unwrap(currency));
    CurrencySettler.take(currency, manager, recipient, amount, claims);
}

function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) {
    CurrencySettler.take(currency, manager, recipient, amount, claims);
}

function normalize(SortResult memory result) view returns (SortResult memory) {
    return SortResult(
        result.token0,
        result.token1,
        TransferHelper.tokenNativeDecimalsToFixed(result.amount0, result.token0),
        TransferHelper.tokenNativeDecimalsToFixed(result.amount1, result.token1)
    );
}

function normalize(address token, uint256 amount) view returns (uint256) {
    return TransferHelper.tokenNativeDecimalsToFixed(amount, token);
}

function normalize(Currency _token, uint256 amount) view returns (uint256) {
    address token = Currency.unwrap(_token);
    return TransferHelper.tokenNativeDecimalsToFixed(amount, token);
}

function toNative(Currency _token, uint256 amount) view returns (uint256) {
    address token = Currency.unwrap(_token);
    return TransferHelper.fixedToTokenNativeDecimals(amount, token);
}

function toNative(address token, uint256 amount) view returns (uint256) {
    return TransferHelper.fixedToTokenNativeDecimals(amount, token);
}

/// @notice Pool state
struct PoolState {
    /// @notice reserve of token0, in the native decimals
    uint256 reserve0;
    /// @notice reserve of token1, in the native decimals
    uint256 reserve1;
    address token0;
    address token1;
    // should be deployed using clones
    LiquidityToken liquidityToken;
    // base fee in 18 decimals, 1% is 1e18\
    uint256 fee;
    uint256 startTimestamp;
    uint256 endTimestamp;
    // treasury split percentage in 18 decimals, 1% is 1e18
    // an amoount equal to treasurySplitPercentage * fee will be sent to the treasury
    uint256 treasurySplitPercentage;
}

library PoolStateLibrary {
    uint256 internal constant MAX_FEE = 100e18;

    /// to prevent price manipulation at the start of the pool
    uint256 internal constant MINIMUM_LIQUIDITY = 1e4;

    function ensureLiquidityEnoughAsNative(PoolState storage state, uint256 amountOut, address token) internal view {
        amountOut = TransferHelper.fixedToTokenNativeDecimals(amountOut, token);

        if (token == state.token0 && state.reserve0 < amountOut) {
            revert IErrors.NotEnoughLiquidity();
        } else if (token == state.token1 && state.reserve1 < amountOut) {
            revert IErrors.NotEnoughLiquidity();
        } else {
            return;
        }
    }

    function updateReserves(PoolState storage state, address token, uint256 amount, bool minus) internal {
        if (token == state.token0) {
            state.reserve0 = minus ? state.reserve0 - amount : state.reserve0 + amount;
        } else if (token == state.token1) {
            state.reserve1 = minus ? state.reserve1 - amount : state.reserve1 + amount;
        } else {
            revert IErrors.InvalidToken();
        }
    }

    function updateReservesAsNative(PoolState storage state, address token, uint256 amount, bool minus) internal {
        amount = TransferHelper.fixedToTokenNativeDecimals(amount, token);
        updateReserves(state, token, amount, minus);
    }

    function updateFee(PoolState storage state, uint256 fee) internal {
        if (fee >= MAX_FEE) {
            revert IErrors.InvalidFee();
        }

        state.fee = fee;
    }

    function getToken0(PoolState storage state) internal view returns (Currency) {
        return Currency.wrap(state.token0);
    }

    function getToken1(PoolState storage state) internal view returns (Currency) {
        return Currency.wrap(state.token1);
    }

    function initialize(PoolState storage state, address _token0, address _token1, address _liquidityToken) internal {
        state.token0 = _token0;
        state.token1 = _token1;
        state.liquidityToken = LiquidityToken(_liquidityToken);
    }

    function isInitialized(PoolState storage state) internal view returns (bool) {
        return state.token0 != address(0);
    }

    function tryAddLiquidity(
        PoolState storage state,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0min,
        uint256 amount1min
    )
        internal
        returns (uint256 reserve0, uint256 reserve1, uint256 mintedLp, uint256 amount0Used, uint256 amount1Used)
    {
        reserve0 = TransferHelper.tokenNativeDecimalsToFixed(state.reserve0, state.token0);
        reserve1 = TransferHelper.tokenNativeDecimalsToFixed(state.reserve1, state.token1);

        (amount0Used, amount1Used) =
            LiquidityMath.inferOptimalAmount(reserve0, reserve1, amount0, amount1, amount0min, amount1min);

        (reserve0, reserve1, mintedLp) =
            LiquidityMath.addLiquidity(reserve0, reserve1, state.liquidityToken.totalSupply(), amount0, amount1);

        reserve0 = TransferHelper.fixedToTokenNativeDecimals(reserve0, state.token0);
        reserve1 = TransferHelper.fixedToTokenNativeDecimals(reserve1, state.token1);

        // we lock minimum liquidity to prevent price manipulation at the start of the pool
        if (state.reserve0 == 0 && state.reserve1 == 0) {
            mintedLp -= MINIMUM_LIQUIDITY;
        }
    }

    function addLiquidity(
        PoolState storage state,
        uint256 amount0,
        uint256 amount1,
        address sender,
        uint256 amount0min,
        uint256 amount1min
    )
        internal
        returns (uint256 reserve0, uint256 reserve1, uint256 mintedLp, uint256 amount0Used, uint256 amount1Used)
    {
        (reserve0, reserve1, mintedLp, amount0Used, amount1Used) =
            tryAddLiquidity(state, amount0, amount1, amount0min, amount1min);

        // we lock minimum liquidity to prevent price manipulation at the start of the pool
        if (state.reserve0 == 0 && state.reserve1 == 0) {
            state.liquidityToken.mint(address(0xd3ad), MINIMUM_LIQUIDITY);
        }

        state.reserve0 = reserve0;
        state.reserve1 = reserve1;
        state.liquidityToken.mint(sender, mintedLp);
    }

    function tryRemoveLiquidity(PoolState storage state, uint256 liquidityAmount)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 reserve0, uint256 reserve1)
    {
        (amount0, amount1, reserve0, reserve1) = LiquidityMath.removeLiquidity(
            state.reserve0, state.reserve1, state.liquidityToken.totalSupply(), liquidityAmount
        );
    }

    function removeLiquidity(PoolState storage state, uint256 liquidityAmount, address sender)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 reserve0, uint256 reserve1)
    {
        (amount0, amount1, reserve0, reserve1) = tryRemoveLiquidity(state, liquidityAmount);

        state.reserve0 = reserve0;
        state.reserve1 = reserve1;
        state.liquidityToken.burnFrom(sender, liquidityAmount);
    }
}
