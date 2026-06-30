// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockSwapHelper — Test version of ATMSwapHelper
 * @notice In tests, the mock router doesn't have INVALID_TO check,
 *         so this helper just proxies through the router like the real one.
 */
interface IMockRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path,
        address to, uint deadline
    ) external;
    function addLiquidity(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

contract MockSwapHelper {
    using SafeERC20 for IERC20;

    address public immutable atmToken;
    address public router;

    constructor(address _atmToken, address _router) {
        atmToken = _atmToken;
        router = _router;
    }

    function swapAndForward(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        require(msg.sender == atmToken, "ONLY_ATM");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(router, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        IMockRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp
        );

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (amountOut > 0) {
            IERC20(tokenOut).safeTransfer(atmToken, amountOut);
        }
    }

    function buyAndAddLiquidity(
        address usdt,
        uint256 usdtForBuy,
        uint256 usdtForLP,
        address lpRecipient
    ) external returns (uint256 liquidity) {
        require(msg.sender == atmToken, "ONLY_ATM");
        uint256 totalUsdt = usdtForBuy + usdtForLP;
        IERC20(usdt).safeTransferFrom(msg.sender, address(this), totalUsdt);
        IERC20(usdt).approve(router, totalUsdt);

        // Buy ATM
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = atmToken;

        uint256 atmBefore = IERC20(atmToken).balanceOf(address(this));

        IMockRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtForBuy, 0, path, address(this), block.timestamp
        );

        uint256 atmBought = IERC20(atmToken).balanceOf(address(this)) - atmBefore;
        IERC20(atmToken).approve(router, atmBought);

        // Add liquidity
        (,, liquidity) = IMockRouter(router).addLiquidity(
            atmToken, usdt,
            atmBought, usdtForLP,
            0, 0,
            lpRecipient,
            block.timestamp
        );

        // Return leftovers
        uint256 remainAtm = IERC20(atmToken).balanceOf(address(this));
        uint256 remainUsdt = IERC20(usdt).balanceOf(address(this));
        if (remainAtm > 0) IERC20(atmToken).safeTransfer(atmToken, remainAtm);
        if (remainUsdt > 0) IERC20(usdt).safeTransfer(atmToken, remainUsdt);
    }

    function recover(address token, uint256 amount) external {
        require(msg.sender == atmToken, "ONLY_ATM");
        IERC20(token).safeTransfer(atmToken, amount);
    }
}
