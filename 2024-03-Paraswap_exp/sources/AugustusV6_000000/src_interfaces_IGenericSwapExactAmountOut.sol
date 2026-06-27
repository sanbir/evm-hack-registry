// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { GenericData } from "../AugustusV6Types.sol";

/// @title IGenericSwapExactAmountOut
/// @notice Interface for executing a generic swapExactAmountOut through an Augustus executor
interface IGenericSwapExactAmountOut is IErrors {
    /*//////////////////////////////////////////////////////////////
                         SWAP EXACT AMOUNT OUT
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a generic swapExactAmountOut using the given executorData on the given executor
    /// @param executor The address of the executor contract to use
    /// @param swapData Generic data containing the swap information
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit The permit data
    /// @param executorData The data to execute on the executor
    /// @return spentAmount The actual amount of tokens used to swap
    /// @return receivedAmount The amount of tokens received from the swap
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountOut(
        address executor,
        GenericData calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata executorData
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
