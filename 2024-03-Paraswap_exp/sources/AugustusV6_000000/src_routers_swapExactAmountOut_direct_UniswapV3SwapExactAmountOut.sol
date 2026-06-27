// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IUniswapV3SwapExactAmountOut } from "../../../interfaces/IUniswapV3SwapExactAmountOut.sol";

// Libraries
import { ERC20Utils } from "../../../libraries/ERC20Utils.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

// Types
import { UniswapV3Data } from "../../../AugustusV6Types.sol";

// Utils
import { UniswapV3Utils } from "../../../util/UniswapV3Utils.sol";
import { WETHUtils } from "../../../util/WETHUtils.sol";
import { Permit2Utils } from "../../../util/Permit2Utils.sol";

/// @title UniswapV3SwapExactAmountOut
/// @notice A contract for executing direct swapExactAmountOut on UniswapV3 pools
abstract contract UniswapV3SwapExactAmountOut is
    IUniswapV3SwapExactAmountOut,
    UniswapV3Utils,
    WETHUtils,
    Permit2Utils
{
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;
    using SafeCastLib for uint256;

    /*//////////////////////////////////////////////////////////////
                         SWAP EXACT AMOUNT OUT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IUniswapV3SwapExactAmountOut
    function swapExactAmountOutOnUniswapV3(
        UniswapV3Data calldata uniData,
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

        // Address that will pay for the swap
        address fromAddress = msg.sender;

        // Check if srcToken is ETH
        bool isFromETH = srcToken.isETH(maxAmountIn) != 0;

        // If pools.length > 96, we are going to do a multi-pool swap
        bool isMultiplePools = pools.length > 96;

        // Init balance before swap
        uint256 balanceBefore;

        // Check if we need to wrap or permit
        if (isFromETH) {
            // If it is ETH. wrap it to WETH
            WETH.deposit{ value: maxAmountIn }();
            // Swap will be paid from this contract
            fromAddress = address(this);
        } else {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            // and if it is >= 257 we execute permit2
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
                // if we're using multiple pools, we need to store the pre-swap balance of srcToken
                if (isMultiplePools) {
                    balanceBefore = srcToken.getBalance(msg.sender);
                }
            } else {
                // Otherwise Permit2.permitTransferFrom
                permit2TransferFrom(permit, address(this), maxAmountIn);
                // Swap will be paid from this contract
                fromAddress = address(this);
            }
        }

        // Execute swap
        (spentAmount, receivedAmount) =
            _callUniswapV3PoolsSwapExactAmountOut((-amountOut.toInt256()), pools, fromAddress);

        // Check if swap succeeded
        if (receivedAmount < amountOut) {
            revert InsufficientReturnAmount();
        }

        // Check if destToken is ETH and unwrap
        if (address(destToken) == address(ERC20Utils.ETH)) {
            // Unwrap WETH
            WETH.withdraw(receivedAmount);
        }

        // Iniiialize remainingAmount
        uint256 remainingAmount;

        // Check if payer is this contract
        if (fromAddress == address(this)) {
            // If srcTokenwas ETH, we need to withdraw remaining WETH if any
            if (isFromETH) {
                // Check balance of WETH
                remainingAmount = IERC20(WETH).getBalance(address(this));
                // Withdraw remaining WETH if any
                if (remainingAmount > 1) {
                    // Unwrap WETH
                    WETH.withdraw(remainingAmount - 1);
                    // Set remainingAmount to this contract's balance
                    remainingAmount = address(this).balance;
                }
            } else {
                // If we have executed multi-pool swap, we need to fetch the remaining amount from balance
                if (isMultiplePools) {
                    // Calculate spent amount and remaining amount
                    remainingAmount = srcToken.getBalance(address(this));
                } else {
                    // Otherwise, remaining amount is the difference between the spent amount and the remaining balance
                    remainingAmount = maxAmountIn - spentAmount;
                }
            }

            // Process fees using processSwapExactAmountOutFeesAndTransfer
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
        } else {
            // If we have executed multi-pool swap, we need to re-calculate the remaining amount and spent amount
            if (isMultiplePools) {
                // Calculate spent amount and remaining amount
                remainingAmount = srcToken.getBalance(msg.sender);
                spentAmount = balanceBefore - remainingAmount;
            }
            // Process fees and transfer destToken and srcToken to feeVault or partner and
            // feeWallet if needed
            return processSwapExactAmountOutFeesAndTransferUniV3(
                beneficiary,
                srcToken,
                destToken,
                partnerAndFee,
                maxAmountIn,
                receivedAmount,
                spentAmount,
                quotedAmountIn
            );
        }
    }
}
