// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IUniswapV2SwapExactAmountOut } from "../../../interfaces/IUniswapV2SwapExactAmountOut.sol";

// Libraries
import { ERC20Utils } from "../../../libraries/ERC20Utils.sol";

// Types
import { UniswapV2Data } from "../../../AugustusV6Types.sol";

// Utils
import { UniswapV2Utils } from "../../../util/UniswapV2Utils.sol";
import { WETHUtils } from "../../../util/WETHUtils.sol";
import { Permit2Utils } from "../../../util/Permit2Utils.sol";

/// @title UniswapV2SwapExactAmountOut
/// @notice A contract for executing direct swapExactAmountOut on UniswapV2 pools
abstract contract UniswapV2SwapExactAmountOut is
    IUniswapV2SwapExactAmountOut,
    UniswapV2Utils,
    WETHUtils,
    Permit2Utils
{
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                         SWAP EXACT AMOUNT OUT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IUniswapV2SwapExactAmountOut
    function swapExactAmountOutOnUniswapV2(
        UniswapV2Data calldata uniData,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        // Dereference uniData
        IERC20 srcToken = uniData.srcToken;
        IERC20 destToken = uniData.destToken;
        uint256 maxAmountIn = uniData.fromAmount;
        uint256 amountOut = uniData.toAmount;
        uint256 quotedAmountIn = uniData.quotedAmount;
        address payable beneficiary = uniData.beneficiary;
        bytes calldata pools = uniData.pools;

        // Check if toAmount is valid
        if (amountOut < 1) {
            revert InvalidToAmount();
        }

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Check if srcToken is ETH
        bool isFromETH = srcToken.isETH(maxAmountIn) != 0;

        // Check if we need to wrap or permit
        if (isFromETH) {
            // If it is ETH. wrap it to WETH
            WETH.deposit{ value: maxAmountIn }();
            // Set srcToken to WETH
            srcToken = WETH;
        } else {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            // and if it is >= 257 we execute permit2
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
                srcToken.safeTransferFrom(msg.sender, address(this), maxAmountIn);
            } else {
                // Otherwise Permit2.permitTransferFrom
                permit2TransferFrom(permit, address(this), maxAmountIn);
            }
        }

        // Execute swap
        _callUniswapV2PoolsSwapExactOut(amountOut, srcToken, pools);

        // Check if destToken is ETH and unwrap
        if (address(destToken) == address(ERC20Utils.ETH)) {
            // Check balance of WETH
            receivedAmount = IERC20(WETH).getBalance(address(this));
            // Leave dust if receivedAmount > amountOut
            if (receivedAmount > amountOut) {
                --receivedAmount;
            }
            // Unwrap WETH
            WETH.withdraw(receivedAmount);
            // Set receivedAmount to this contract's balance
            receivedAmount = address(this).balance;
        } else {
            // Othwerwise check balance of destToken
            receivedAmount = destToken.getBalance(address(this));
        }

        // Check balance of srcToken
        uint256 remainingAmount = srcToken.getBalance(address(this));

        // Check if swap succeeded
        if (receivedAmount < amountOut) {
            revert InsufficientReturnAmount();
        }

        // Check if srcToken is ETH and unwrap if there is remaining amount
        if (isFromETH) {
            // Withdraw remaining WETH if any
            if (remainingAmount > 1) {
                WETH.withdraw(remainingAmount - 1);
            }
            srcToken = ERC20Utils.ETH;
            // Set remainingAmount to this contract's balance
            remainingAmount = address(this).balance;
        }

        // Process fees and transfer destToken and srcToken to beneficiary
        return processSwapExactAmountOutFeesAndTransfer(
            beneficiary,
            srcToken,
            destToken,
            partnerAndFee,
            maxAmountIn,
            remainingAmount,
            receivedAmount,
            quotedAmountIn
        );
    }
}
