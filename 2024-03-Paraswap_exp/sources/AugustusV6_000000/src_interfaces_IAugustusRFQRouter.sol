// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IErrors } from "./IErrors.sol";

// Types
import { AugustusRFQData, OrderInfo } from "../AugustusV6Types.sol";

/// @title IAugustusRFQRouter
/// @notice Interface for direct swaps on AugustusRFQ
interface IAugustusRFQRouter is IErrors {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the passed msg.value is not equal to the fromAmount
    error IncorrectEthAmount();

    /*//////////////////////////////////////////////////////////////
                             TRY BATCH FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a tryBatchFillTakerAmount or tryBatchFillMakerAmount call on AugustusRFQ
    /// the function that is executed is defined by the direction flag in the data param
    /// @param data Struct containing common data for AugustusRFQ
    /// @param orders An array containing AugustusRFQ orderInfo data
    /// @param permit Permit data for the swap
    /// @return spentAmount The amount of tokens spent
    /// @return receivedAmount The amount of tokens received
    function swapExactAmountInOutOnAugustusRFQTryBatchFill(
        AugustusRFQData calldata data,
        OrderInfo[] calldata orders,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount);
}
