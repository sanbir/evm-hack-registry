// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IUniswapV2SwapExactAmountIn } from "../../../interfaces/IUniswapV2SwapExactAmountIn.sol";

// Libraries
import { ERC20Utils } from "../../../libraries/ERC20Utils.sol";

// Types
import { UniswapV2Data } from "../../../AugustusV6Types.sol";

// Utils
import { UniswapV2Utils } from "../../../util/UniswapV2Utils.sol";
import { WETHUtils } from "../../../util/WETHUtils.sol";
import { Permit2Utils } from "../../../util/Permit2Utils.sol";

/// @title UniswapV2SwapExactAmountIn
/// @notice A contract for executing direct swapExactAmountIn on UniswapV2 pools
abstract contract UniswapV2SwapExactAmountIn is
    IUniswapV2SwapExactAmountIn,
    UniswapV2Utils,
    WETHUtils,
    Permit2Utils
{
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                                   SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IUniswapV2SwapExactAmountIn
    function swapExactAmountInOnUniswapV2(
        UniswapV2Data calldata uniData,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        // Dereference uniData
        IERC20 srcToken = uniData.srcToken;
        IERC20 destToken = uniData.destToken;
        uint256 amountIn = uniData.fromAmount;
        uint256 minAmountOut = uniData.toAmount;
        uint256 quotedAmountOut = uniData.quotedAmount;
        address payable beneficiary = uniData.beneficiary;
        bytes calldata pools = uniData.pools;

        // Initialize payer
        address payer = msg.sender;

        // Check if toAmount is valid
        if (minAmountOut < 1) {
            revert InvalidToAmount();
        }

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Check if we need to wrap or permit
        if (srcToken.isETH(amountIn) == 0) {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
            }
        } else {
            // If it is ETH. wrap it to WETH
            WETH.deposit{ value: amountIn }();
            // Set srcToken to WETH
            srcToken = WETH;
            // Set payer to this contract
            payer = address(this);
        }

        // Execute swap
        _callUniswapV2PoolsSwapExactIn(amountIn, srcToken, pools, payer, permit);

        // Check if destToken is ETH and unwrap
        if (address(destToken) == address(ERC20Utils.ETH)) {
            // Check balance of WETH
            receivedAmount = IERC20(WETH).getBalance(address(this));
            // Unwrap WETH
            WETH.withdraw(receivedAmount - 1);
            // Set receivedAmount to this contract's balance
            receivedAmount = address(this).balance;
        } else {
            // Othwerwise check balance of destToken
            receivedAmount = destToken.getBalance(address(this));
        }

        // Check if swap succeeded
        if (receivedAmount < minAmountOut) {
            revert InsufficientReturnAmount();
        }

        // Process fees and transfer destToken to beneficiary
        return processSwapExactAmountInFeesAndTransfer(
            beneficiary, destToken, partnerAndFee, receivedAmount, quotedAmountOut
        );
    }
}
