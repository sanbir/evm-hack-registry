// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV2Router02.sol";

/**
 * @title SwapHelper
 * @notice 统一封装协议内部使用的 Pancake Router 操作。
 * @dev BY/BYB/BYC 自有池内部换币使用 0 minOut，避免协议流程因自有池滑点失败。
 *      BNB/USDT 这类外部稳定资产兑换仍按 slippageTolerance 计算 minOut。
 */
library SwapHelper {
    using SafeERC20 for IERC20;

    /**
     * @notice 将协议持有的 token 卖成 BNB。
     * @dev 用于赎回亏损路径、节点/利息资金补足等场景。返回实际新增的 BNB 数量。
     */
    function swapTokenToBNB(
        IERC20 token,
        IUniswapV2Router02 router,
        uint256 amount
    ) internal returns (uint256 bnbOut) {
        if (amount == 0) return 0;

        address WETH = router.WETH();
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = WETH;

        token.safeApprove(address(router), 0);
        token.safeApprove(address(router), amount);

        uint256 before = address(this).balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 300
        );
        bnbOut = address(this).balance - before;
        return bnbOut;
    }

    /**
     * @notice 确保当前合约 BNB 余额足够支付指定金额。
     * @dev 如果 BNB 不足，会按需卖出 token；若 token 余额不足则卖出全部并再次校验。
     */
    function ensureBNBBalance(
        IERC20 token,
        IUniswapV2Router02 router,
        uint256 needed
    ) internal {
        if (address(this).balance >= needed) return;

        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "Insufficient Token to swap for BNB");

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = router.WETH();

        uint256 tokenNeeded = router.getAmountsIn(needed, path)[0];
        if (tokenNeeded > tokenBalance) {
            swapTokenToBNB(token, router, tokenBalance);
            require(address(this).balance >= needed, "Insufficient liquidity");
        } else {
            swapTokenToBNB(token, router, tokenNeeded);
            require(
                address(this).balance >= needed,
                "Swap output insufficient"
            );
        }
    }

    /**
     * @notice 使用 BNB 买入 token，并和剩余 BNB 一起添加永久流动性。
     * @dev 质押时会把扣税后的 BNB 分成两半：一半买 BY，一半与 BY 加池。
     *      LP 直接发送到 0xdead 永久锁定；amountMin 为 0，按业务要求优先保证交易执行成功。
     */
    function buyAndAddLiquidity(
        IERC20 token,
        IUniswapV2Router02 router,
        address,
        uint256 toPool
    ) internal returns (uint256 redeemBNBAmount) {
        if (toPool == 0) return 0;

        address WETH = router.WETH();
        uint256 bnbForBuy = (toPool * 50) / 100;
        uint256 bnbToLiquidity = toPool - bnbForBuy;
        uint256 byBefore = token.balanceOf(address(this));

        if (bnbForBuy > 0) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = address(token);
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: bnbForBuy
            }(0, path, address(this), block.timestamp + 300);
        }

        uint256 tokenAmount = token.balanceOf(address(this)) - byBefore;
        if (tokenAmount == 0 || bnbToLiquidity == 0) return 0;

        token.safeApprove(address(router), 0);
        token.safeApprove(address(router), tokenAmount);
        (, uint256 amountETHUsed, ) = router.addLiquidityETH{
            value: bnbToLiquidity
        }(
            address(token),
            tokenAmount,
            0,
            0,
            address(0xdead),
            block.timestamp + 300
        );
        return bnbForBuy + amountETHUsed;
    }

    /**
     * @notice 移除 LP 流动性，取回 BNB 和 token。
     * @dev 赎回订单时调用。removeLiquidityETH 的 amountMin 为 0，按业务要求优先保证交易执行成功。
     */
    function removeLiquidity(
        IERC20 token,
        IUniswapV2Router02 router,
        address pool,
        uint256 lpAmount
    ) internal returns (uint256 bnbOut, uint256 tokenOut) {
        IERC20(pool).approve(address(router), lpAmount);
        (uint256 amounToken, uint256 amountBNB) = router.removeLiquidityETH(
            address(token),
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp + 300
        );
        return (amountBNB, amounToken);
    }

    /**
     * @notice 将 BNB 换成 USDT。
     * @dev 用于盈利赎回路径，将移除流动性得到的 BNB 兑换给用户。
     */
    function swapBNBToUSDT(
        IUniswapV2Router02 router,
        IERC20 usdt,
        uint256 bnbAmount,
        uint256 slippageTolerance
    ) internal returns (uint256 usdtOut) {
        if (bnbAmount == 0) return 0;

        address WETH = router.WETH();
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = address(usdt);

        uint256 expected = router.getAmountsOut(bnbAmount, path)[1];
        uint256 minOut = (expected * (100 - slippageTolerance)) / 100;
        uint256 before = usdt.balanceOf(address(this));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: bnbAmount
        }(minOut, path, address(this), block.timestamp + 300);
        return usdt.balanceOf(address(this)) - before;
    }

    /**
     * @notice 将 token 经由 WBNB 路径换成 USDT。
     * @dev 用于盈利赎回路径，将移除流动性得到的 BY 兑换成 USDT。
     */
    function swapTokenToUSDT(
        IERC20 token,
        IUniswapV2Router02 router,
        IERC20 usdt,
        uint256 tokenAmount,
        uint256 slippageTolerance
    ) internal returns (uint256 usdtOut) {
        if (tokenAmount == 0) return 0;

        address WETH = router.WETH();
        address[] memory path = new address[](3);
        path[0] = address(token);
        path[1] = WETH;
        path[2] = address(usdt);

        uint256 expected = router.getAmountsOut(tokenAmount, path)[2];
        uint256 minOut = (expected * (100 - slippageTolerance)) / 100;
        token.safeApprove(address(router), 0);
        token.safeApprove(address(router), tokenAmount);
        uint256 before = usdt.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );
        return usdt.balanceOf(address(this)) - before;
    }

    /**
     * @notice 使用 BNB 买入指定 token 后立即销毁。
     * @dev 利息领取中的 5% 买入销毁 BYC 走这里；通过低级调用兼容 token 自身 burn 接口。
     */
    function buyAndBurnToken(
        IERC20 token,
        IUniswapV2Router02 router,
        uint256 bnbAmount
    ) internal returns (uint256 tokenBurned) {
        if (bnbAmount == 0) return 0;

        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(token);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: bnbAmount
        }(0, path, address(this), block.timestamp + 300);

        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            (bool success, ) = address(token).call(
                abi.encodeWithSignature("burn(uint256)", balance)
            );
            require(success, "Burn failed");
            tokenBurned = balance;
        }
        return tokenBurned;
    }
}
