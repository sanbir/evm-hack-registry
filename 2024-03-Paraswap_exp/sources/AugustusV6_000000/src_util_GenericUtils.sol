// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Contracts
import { AugustusFees } from "../fees/AugustusFees.sol";

/// @title GenericUtils
/// @notice A contract containing common utilities for Generic swaps
abstract contract GenericUtils is AugustusFees {
    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Call executor with executorData and amountIn
    function _callSwapExactAmountInExecutor(
        address executor,
        bytes calldata executorData,
        uint256 amountIn
    )
        internal
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // get the length of the executorData
            // + 4 bytes for the selector
            // + 32 bytes for fromAmount
            // + 32 bytes for sender
            let totalLength := add(executorData.length, 68)
            calldatacopy(add(0x7c, 4), executorData.offset, executorData.length) // store the executorData
            mstore(add(0x7c, add(4, executorData.length)), amountIn) // store the amountIn
            mstore(add(0x7c, add(36, executorData.length)), caller()) // store the sender
            // call executor and forward call value
            if iszero(call(gas(), executor, callvalue(), 0x7c, totalLength, 0, 0)) {
                returndatacopy(0x7c, 0, returndatasize()) // copy the revert data to memory
                revert(0x7c, returndatasize()) // revert with the revert data
            }
        }
    }

    /// @dev Call executor with executorData, maxAmountIn, amountOut
    function _callSwapExactAmountOutExecutor(
        address executor,
        bytes calldata executorData,
        uint256 maxAmountIn,
        uint256 amountOut
    )
        internal
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // get the length of the executorData
            // + 4 bytes for the selector
            // + 32 bytes for fromAmount
            // + 32 bytes for toAmount
            // + 32 bytes for sender
            let totalLength := add(executorData.length, 100)
            calldatacopy(add(0x7c, 4), executorData.offset, executorData.length) // store the executorData
            mstore(add(0x7c, add(4, executorData.length)), maxAmountIn) // store the maxAmountIn
            mstore(add(0x7c, add(36, executorData.length)), amountOut) // store the amountOut
            mstore(add(0x7c, add(68, executorData.length)), caller()) // store the sender
            // call executor and forward call value
            if iszero(call(gas(), executor, callvalue(), 0x7c, totalLength, 0, 0)) {
                returndatacopy(0x7c, 0, returndatasize()) // copy the revert data to memory
                revert(0x7c, returndatasize()) // revert with the revert data
            }
        }
    }
}
