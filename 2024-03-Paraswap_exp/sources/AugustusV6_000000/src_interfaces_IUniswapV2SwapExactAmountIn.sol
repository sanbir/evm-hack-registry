// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { UniswapV2Data } from "../AugustusV6Types.sol";

/// @title IUniswapV2SwapExactAmountIn
/// @notice Interface for direct swaps on Uniswap V2
interface IUniswapV2SwapExactAmountIn is IErrors {
    /*//////////////////////////////////////////////////////////////
                         SWAP EXACT AMOUNT OUT
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a swapExactAmountIn on Uniswap V2 pools
    /// @param uniData struct containing data for the swap
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit The permit data
    /// @return receivedAmount The amount of destToken received after fees
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountInOnUniswapV2(
        UniswapV2Data calldata uniData,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
