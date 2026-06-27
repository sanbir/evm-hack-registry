// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { CurveV1Data } from "../AugustusV6Types.sol";

/// @title ICurveV1SwapExactAmountIn
/// @notice Interface for direct swaps on Curve V1
interface ICurveV1SwapExactAmountIn is IErrors {
    /*//////////////////////////////////////////////////////////////
                          SWAP EXACT AMOUNT IN
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a swapExactAmountIn on Curve V1 pools
    /// @param curveV1Data Struct containing data for the swap
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit Permit data for the swap
    /// @return receivedAmount The amount of destToken received after fees
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountInOnCurveV1(
        CurveV1Data calldata curveV1Data,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
