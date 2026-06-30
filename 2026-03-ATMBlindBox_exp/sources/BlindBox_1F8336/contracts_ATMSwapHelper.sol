// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPancakeRouter02 {
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

/**
 * @title ATMSwapHelper
 * @notice PancakeSwap V2 Pair restricts swap output to token addresses in the pair
 *         ("INVALID_TO"). Since ATMToken is a pair token, it cannot receive swap output
 *         directly. This helper acts as an intermediary.
 * 
 *         Only the ATMToken contract can call swap functions (onlyATM modifier).
 *         All received tokens are forwarded back to ATMToken in the same tx.
 */
contract ATMSwapHelper {
    using SafeERC20 for IERC20;

    address public immutable atmToken;
    address public immutable router;

    modifier onlyATM() {
        require(msg.sender == atmToken, "ONLY_ATM");
        _;
    }

    constructor(address _atmToken, address _router) {
        atmToken = _atmToken;
        router = _router;
    }

    /**
     * @notice Swap tokenIn → tokenOut via router, forward output to ATMToken
     * @param tokenIn  Token to sell (ATM or USDT)
     * @param tokenOut Token to buy (USDT or ATM)
     * @param amountIn Amount of tokenIn to swap
     * @return amountOut Actual amount of tokenOut forwarded to ATMToken
     */
    function swapAndForward(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external onlyATM returns (uint256 amountOut) {
        // Pull tokenIn from ATMToken
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve router
        IERC20(tokenIn).approve(router, amountIn);

        // Record balance before
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        // Swap
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        IPancakeRouter02(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),  // Helper receives the output (not a pair token)
            block.timestamp
        );

        // Calculate actual output
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        // Forward all output to ATMToken
        if (amountOut > 0) {
            IERC20(tokenOut).safeTransfer(atmToken, amountOut);
        }
    }

    /**
     * @notice Buy ATM back and add liquidity (for P9)
     * @param usdtForBuy  USDT to swap for ATM
     * @param usdtForLP   USDT to pair with bought ATM for LP
     * @param lpRecipient Who receives the LP tokens
     * @return liquidity  LP tokens minted
     */
    function buyAndAddLiquidity(
        address usdt,
        uint256 usdtForBuy,
        uint256 usdtForLP,
        address lpRecipient
    ) external onlyATM returns (uint256 liquidity) {
        uint256 totalUsdt = usdtForBuy + usdtForLP;
        IERC20(usdt).safeTransferFrom(msg.sender, address(this), totalUsdt);

        // Approve router for USDT
        IERC20(usdt).approve(router, totalUsdt);

        // Buy ATM with first half
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = atmToken;

        uint256 atmBefore = IERC20(atmToken).balanceOf(address(this));

        IPancakeRouter02(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtForBuy,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 atmBought = IERC20(atmToken).balanceOf(address(this)) - atmBefore;

        // Approve router for ATM
        IERC20(atmToken).approve(router, atmBought);

        // Add liquidity
        (,, liquidity) = IPancakeRouter02(router).addLiquidity(
            atmToken,
            usdt,
            atmBought,
            usdtForLP,
            0, 0,
            lpRecipient,
            block.timestamp
        );

        // Return any remaining tokens to ATMToken
        uint256 remainAtm = IERC20(atmToken).balanceOf(address(this));
        uint256 remainUsdt = IERC20(usdt).balanceOf(address(this));
        if (remainAtm > 0) IERC20(atmToken).safeTransfer(atmToken, remainAtm);
        if (remainUsdt > 0) IERC20(usdt).safeTransfer(atmToken, remainUsdt);
    }

    /// @notice Emergency: recover stuck tokens (only ATM contract can call)
    function recover(address token, uint256 amount) external onlyATM {
        IERC20(token).safeTransfer(atmToken, amount);
    }
}
