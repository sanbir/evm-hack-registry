// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { CurveV2Data } from "../AugustusV6Types.sol";

/// @title ICurveV2SwapExactAmountIn
/// @notice Interface for direct swaps on Curve V2
interface ICurveV2SwapExactAmountIn is IErrors {
    /*//////////////////////////////////////////////////////////////
                          SWAP EXACT AMOUNT IN
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a swapExactAmountIn on Curve V2 pools
    /// @param curveV2Data Struct containing data for the swap
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit Permit data for the swap
    /// @return receivedAmount The amount of destToken received after fees
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountInOnCurveV2(
        CurveV2Data calldata curveV2Data,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
