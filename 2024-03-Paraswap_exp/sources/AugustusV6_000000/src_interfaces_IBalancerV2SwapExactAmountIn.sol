// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { BalancerV2Data } from "../AugustusV6Types.sol";

/// @title IBalancerV2SwapExactAmountIn
/// @notice Interface for executing swapExactAmountIn directly on Balancer V2 pools
interface IBalancerV2SwapExactAmountIn is IErrors {
    /*//////////////////////////////////////////////////////////////
                          SWAP EXACT AMOUNT IN
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a swapExactAmountIn on Balancer V2 pools
    /// @param balancerData Struct containing data for the swap
    /// @param partnerAndFee packed partner address and fee percentage, the first 12 bytes is the feeData and the last
    /// 20 bytes is the partner address
    /// @param permit Permit data for the swap
    /// @param data The calldata to execute
    /// the first 20 bytes are the beneficiary address and the left most bit is the approve flag
    /// @return receivedAmount The amount of destToken received after fees
    /// @return paraswapShare The share of the fees for Paraswap
    /// @return partnerShare The share of the fees for the partner
    function swapExactAmountInOnBalancerV2(
        BalancerV2Data calldata balancerData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata data
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare);
}
