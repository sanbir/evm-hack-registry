pragma solidity >=0.5.0;

import "../interfaces/IBabyDogePair.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IBabyDogeRouter.sol";
import "./SafeMath.sol";

library BabyDogeLibrary {
    using SafeMath for uint256;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Library: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        factory,
                        keccak256(abi.encodePacked(token0, token1)),
                        hex"5646bd1da4b93040d09d9a44666ac5ad7d4eb0711841defc40f00dce1aba0b06" // init code hash
                    )
                )
            )
        );
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IBabyDogePair(
            pairFor(factory, tokenA, tokenB)
        ).getReserves();
        (reserveA, reserveB) = tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "BabyDogeLibrary: INSUFFICIENT_AMOUNT");
        require(
            reserveA > 0 && reserveB > 0,
            "BabyDogeLibrary: INSUFFICIENT_LIQUIDITY"
        );
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn.mul(fee);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fee
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "BabyDogeLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn.mul(amountOut).mul(1000000);
        uint256 denominator = reserveOut.sub(amountOut).mul(fee);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path,
        address router
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "Library: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(
                factory,
                path[i],
                path[i + 1]
            );
            uint256 fee = IBabyDogeRouter(router).transactionFee(
                path[i],
                path[i + 1],
                // bugfix: when transactionFee called from this library
                //         the msg.sender is contract where the library is embeded
                msg.sender 
            );
            amounts[i + 1] = getAmountOut(
                amounts[i],
                reserveIn,
                reserveOut,
                fee
            );
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path,
        address router
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "PancakeLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(
                factory,
                path[i - 1],
                path[i]
            );
            uint256 fee = IBabyDogeRouter(router).transactionFee(
                path[i - 1],
                path[i],
                msg.sender
            );
            amounts[i - 1] = getAmountIn(
                amounts[i],
                reserveIn,
                reserveOut,
                fee
            );
        }
    }
}
