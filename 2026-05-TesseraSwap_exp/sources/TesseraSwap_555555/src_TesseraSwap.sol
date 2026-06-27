// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITesseraEngine {
    function swapAmount(address tokenIn, address tokenOut, int256 amountSpecified, address sender, bytes calldata swapData) external returns (uint256, uint256);
    function swapAmountView(address tokenIn, address tokenOut, int256 amountSpecified, address sender) external view returns (uint256 amountIn, uint256 amountOut);
}

interface ITesseraSwapCallback {
    function tesseraSwapCallback(int256,int256,bytes calldata) external;
}

contract TesseraSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;
    ITesseraEngine tesseraEngine;
    address tesseraTreasury;
    address tesseraOwner;

    event TesseraTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient);

    constructor(address _tesseraEngine, address _tesseraTreasury, address _tesseraOwner){
        tesseraEngine = ITesseraEngine(_tesseraEngine);
        tesseraTreasury = _tesseraTreasury;
        tesseraOwner = _tesseraOwner;
    }

    function tesseraSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata swapData
    ) external {
        (uint256 amountIn, uint256 amountOut) = tesseraEngine.swapAmount(tokenIn, tokenOut, amountSpecified, msg.sender, swapData);
        require(amountSpecified > 0 ? amountOut >= amountCheck : amountIn <= amountCheck, "ACF");
        IERC20(tokenOut).safeTransferFrom(tesseraTreasury, recipient, amountOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, tesseraTreasury, amountIn);

        emit TesseraTrade(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function tesseraSwapWithCallback(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient,
        bytes calldata callbackData,
        bytes calldata swapData
    ) external nonReentrant {
        (uint256 amountIn, uint256 amountOut) = tesseraEngine.swapAmount(tokenIn, tokenOut, amountSpecified, msg.sender, swapData);
        require(amountSpecified > 0 ? amountOut >= amountCheck : amountIn <= amountCheck, "ACF");

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenOut).safeTransferFrom(tesseraTreasury, recipient, amountOut);
        ITesseraSwapCallback(msg.sender).tesseraSwapCallback(int256(amountIn), -int256(amountOut), callbackData);
        require(IERC20(tokenIn).balanceOf(address(this)) >= balanceBefore + amountIn, "WTA");
        IERC20(tokenIn).safeTransfer(tesseraTreasury, amountIn);

        emit TesseraTrade(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function tesseraSwapViewAmounts(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut) = ITesseraEngine(tesseraEngine).swapAmountView(tokenIn, tokenOut, amountSpecified, msg.sender);
    }

    function changeTesseraEngine(address newTesseraEngine) external {
        require(msg.sender == tesseraOwner, "ACE");
        tesseraEngine = ITesseraEngine(newTesseraEngine);
    }

    function changeTesseraTreasury(address newTesseraTreasury) external {
        require(msg.sender == tesseraOwner, "ACE");
        tesseraTreasury = newTesseraTreasury;
    }

    function rescueTokens(address[] memory tokens, uint256[] memory amounts) external {
        require(msg.sender == tesseraOwner, "ACE");
        address tokenAddress;
        uint256 tokenAmount;
        for (uint256 i=0; i<tokens.length; ++i){
            tokenAddress = tokens[i];
            tokenAmount = amounts[i];
            if (tokenAddress == address(0)){
                (bool success, ) = tesseraTreasury.call{value: tokenAmount}("");
                require(success, "ETH transfer failed");
                continue;
            }
            IERC20(tokenAddress).safeTransfer(tesseraTreasury, tokenAmount);
        }
    }
}