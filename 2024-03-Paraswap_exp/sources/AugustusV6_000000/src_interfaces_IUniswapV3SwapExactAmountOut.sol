// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { UniswapV3Data } from "../AugustusV6Types.sol";

/// @title IUniswapV3SwapExactAmountOut
/// @notice Interface for executing direct swapExactAmountOut on Uniswap V3
interface IUniswapV3SwapExactAmountOut is IErrors {
    /*//////////////////////////////////////////////////////////////
                         SWAP EXACT AMOUNT OUT
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a swapExactAmountOut on Uniswap V3 pools
    /// @param swapData struct containing data for the swap
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit The permit data
    /// @return spentAmount The actual amount of tokens used to swap
    /// @return receivedAmount The amount of tokens received
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountOutOnUniswapV3(
        UniswapV3Data calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
