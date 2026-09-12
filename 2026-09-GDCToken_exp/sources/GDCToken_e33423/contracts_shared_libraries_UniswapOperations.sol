// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IUniswapV2.sol";

library UniswapOperations {
    struct Reserves {
        uint256 rOther;
        uint256 rThis;
        uint256 balanceOther;
    }

    function getReserves(
        address uniswapPair,
        address baseTokenAddress,
        address tokenAddress
    ) internal view returns (Reserves memory reserves) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapPair);
        (uint256 r0, uint256 r1, ) = mainPair.getReserves();

        address tokenOther = baseTokenAddress;
        if (tokenOther < tokenAddress) {
            reserves.rOther = r0;
            reserves.rThis = r1;
        } else {
            reserves.rOther = r1;
            reserves.rThis = r0;
        }

        reserves.balanceOther = IERC20(tokenOther).balanceOf(uniswapPair);
    }

    function isAddLiquidity(
        address uniswapPair,
        address baseTokenAddress,
        address tokenAddress,
        address routerFactory,
        uint256 amount
    ) internal view returns (uint256 liquidity) {
        Reserves memory reserves = getReserves(uniswapPair, baseTokenAddress, tokenAddress);
        uint256 amountOther;
        if (reserves.rOther > 0 && reserves.rThis > 0) {
            amountOther = (amount * reserves.rOther) / reserves.rThis;
        }
        if (reserves.balanceOther >= reserves.rOther + amountOther) {
            (liquidity, ) = calculateLiquidity(
                uniswapPair,
                routerFactory,
                reserves.balanceOther,
                amount,
                reserves.rOther,
                reserves.rThis
            );
        }
    }

    function isRemoveLiquidity(
        address uniswapPair,
        address baseTokenAddress,
        address tokenAddress,
        uint256 amount,
        uint256 tokenBalance
    ) internal view returns (uint256 liquidity) {
        Reserves memory reserves = getReserves(uniswapPair, baseTokenAddress, tokenAddress);
        if (reserves.balanceOther <= reserves.rOther) {
            liquidity = (amount * IUniswapV2Pair(uniswapPair).totalSupply()) / (tokenBalance - amount);
        }
    }

    function calculateLiquidity(
        address uniswapPair,
        address routerFactory,
        uint256 balanceA,
        uint256 amount,
        uint256 r0,
        uint256 r1
    ) internal view returns (uint256 liquidity, uint256 feeToLiquidity) {
        uint256 pairTotalSupply = IUniswapV2Pair(uniswapPair).totalSupply();
        address feeTo = IUniswapV2Factory(routerFactory).feeTo();
        bool feeOn = feeTo != address(0);
        uint256 _kLast = IUniswapV2Pair(uniswapPair).kLast();
        
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(r0 * r1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = pairTotalSupply * (rootK - rootKLast) * 8;
                    uint256 denominator = rootK * 17 + (rootKLast * 8);
                    feeToLiquidity = numerator / denominator;
                    if (feeToLiquidity > 0) pairTotalSupply += feeToLiquidity;
                }
            }
        }
        
        uint256 amount0 = balanceA - r0;
        if (pairTotalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount) - 1000;
        } else {
            liquidity = Math.min(
                (amount0 * pairTotalSupply) / r0,
                (amount * pairTotalSupply) / r1
            );
        }
    }

    function addLiquidity(
        IUniswapV2Router02 router,
        address bnbTokenAddress,
        address tokenAddress,
        uint256 tokenAmtA,
        uint256 tokenAmtB,
        address recipient
    ) internal returns (uint256) {
        router.addLiquidity(
            bnbTokenAddress,
            tokenAddress,
            tokenAmtA,
            tokenAmtB,
            0,
            0,
            recipient,
            block.timestamp + 600
        );

        // 需要调用者传入 pair 地址，因为库函数无法直接获取
        // 返回的 LP token 数量由调用者计算
        return 0; // 占位符，实际在主合约中计算
    }

    /// @dev 单边 BNB 加池时应先 swap 的数量，使 swap 后剩余 BNB 与换得 GDC 匹配池比例
    /// @param reserveIn 池内 BNB/WBNB 储备（与 amountIn 同侧）
    /// @param amountIn 可用于 LP 的 BNB 总量
    /// @param feeBps swap 手续费基点（Pancake V2 = 25，即 0.25%）
    function optimalSwapIn(uint256 reserveIn, uint256 amountIn, uint256 feeBps) internal pure returns (uint256 s) {
        if (reserveIn == 0 || amountIn == 0) {
            return 0;
        }
        uint256 f = 10000 - feeBps;
        uint256 a = 20000 - feeBps;
        uint256 radicand = reserveIn * (reserveIn * a * a + 4 * f * 10000 * amountIn);
        s = (Math.sqrt(radicand) - reserveIn * a) / (2 * f);
        if (s > amountIn) {
            s = amountIn;
        }
    }

    function wrapEth(address bnbTokenAddress, uint256 value) internal {
        IWETH(bnbTokenAddress).deposit{value: value}();
    }

    function isLpValueAboveThreshold(
        address uniswapPair,
        address bnbTokenAddress,
        address user,
        uint256 minAmount
    ) internal view returns (bool) {
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();

        if (totalSupply == 0) return false;

        address token0 = pair.token0();
        uint256 reserveBNB = token0 == bnbTokenAddress ? reserve0 : reserve1;

        uint256 userLP = pair.balanceOf(user);
        uint256 userShare = (userLP * 1e18) / totalSupply;
        uint256 bnbAmount = (reserveBNB * userShare) / 1e18;
        uint256 lpValueInBNB = bnbAmount * 2;

        return lpValueInBNB >= minAmount / 2;
    }
}
