// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/**
 * @title ISafe
 * @notice An interface defining the core functions that a module can use to execute transactions
 * and interact with the assets of a Gnosis Safe. It provides methods for executing transactions
 * with and without retrieving the return data from the called contract.
 */
interface ISafe {
    /**
     * @notice Executes a transaction on behalf of the safe from a trusted module.
     * @dev The return value only indicates if the call was successful (`true`) or if it reverted (`false`).
     * It does not provide the return data of the external call.
     * @param to The address of the target of the transaction.
     * @param value The amount of native currency (e.g., ETH) to send.
     * @param data The encoded function call data.
     * @param operation The type of operation to perform (e.g., `CALL`, `DELEGATECALL`).
     * @return success A boolean indicating whether the external call succeeded.
     */
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);

    /**
     * @notice Executes a transaction on behalf of the safe from a trusted module and returns the raw return data.
     * @dev This function is a more versatile version of `execTransactionFromModule` as it also returns the
     * raw data of the executed call, which can be useful for modules that need to read return values.
     * @param to The address of the target of the transaction.
     * @param value The amount of native currency (e.g., ETH) to send.
     * @param data The encoded function call data.
     * @param operation The type of operation to perform (e.g., `CALL`, `DELEGATECALL`).
     * @return success A boolean indicating whether the external call succeeded.
     * @return returnData The raw return data from the external call.
     */
    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation
    ) external returns (bool success, bytes memory returnData);
}
