// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IUniswapV2.sol";

library SwapOperations {
    error SendETHToSwap();
    error InvalidInputAmount();
    error InsufficientTokenA();
    error InsufficientTokenB();

    function ethToTokenSwap(
        IUniswapV2Router02 router,
        address distributor,
        address bnbTokenAddress,
        address toToken,
        address tokenContract,
        uint256 amount,
        address recipient
    ) internal returns (uint256) {
        if (msg.value == 0) revert SendETHToSwap();

        address[] memory path = new address[](2);
        path[0] = bnbTokenAddress;
        path[1] = toToken;

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            distributor,
            block.timestamp + 600
        );

        uint256 balanceAfter = IERC20(toToken).balanceOf(distributor);

        if (toToken != tokenContract) {
            IERC20(toToken).transferFrom(distributor, recipient, balanceAfter);
        }
        // 如果 toToken == tokenContract，需要主合约调用 _update

        return balanceAfter;
    }

    function tokenToTokenSwap(
        IUniswapV2Router02 router,
        address distributor,
        address bnbTokenAddress,
        address tokenContract,
        address toToken,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256) {
        if (amountIn == 0) revert InvalidInputAmount();

        address[] memory path = new address[](3);
        path[0] = tokenContract;
        path[1] = bnbTokenAddress;
        path[2] = toToken;

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            distributor,
            block.timestamp + 600
        );

        uint256 balanceAfter = IERC20(toToken).balanceOf(distributor);
        if (toToken != tokenContract) {
            IERC20(toToken).transferFrom(distributor, recipient, balanceAfter);
        }
        // 如果 toToken == tokenContract，需要主合约调用 _update

        return balanceAfter;
    }

    function tokenToEthSwap(
        IUniswapV2Router02 router,
        address bnbTokenAddress,
        address tokenContract,
        uint256 amountIn,
        address recipient
    ) internal {
        if (amountIn == 0) revert InvalidInputAmount();

        address[] memory path = new address[](2);
        path[0] = tokenContract;
        path[1] = bnbTokenAddress;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            recipient,
            block.timestamp + 600
        );
    }
}
