// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/**
 * @title IDelegateBundler
 * @notice An interface for a contract that enables a single transaction
 * to bundle and execute multiple calls on behalf of a delegate.
 */
interface IDelegateBundler {
    /**
     * @notice A struct representing a single call with its destination, data, and value.
     * @param to The address of the contract to call.
     * @param data The calldata to be sent with the call.
     * @param value The amount of native currency (e.g., ETH) to send with the call.
     */
    struct Call {
        address to;
        bytes data;
        uint256 value;
    }

    /**
     * @notice The result of a single call execution within a batch.
     * @param success True if the call was successful, false otherwise.
     * @param returnData The returned data from the call execution.
     */
    struct CallResult {
        bool success;
        bytes returnData;
    }

    /**
     * @notice Thrown when the provided array of calls is empty.
     */
    error ZeroCallsArr();
    /**
     * @notice Thrown when the signature provided by the delegate is invalid.
     */
    error InvalidDelegateSignature();
    /**
     * @notice Thrown when the signature provided has expired.
     * @param deadline The expiration timestamp for the signature.
     */
    error SignatureExpired(uint256 deadline);

    /**
     * @notice Thrown after simulating a batch execution, returning the array of success flags for each call.
     * @param successArr Array indicating success (true) or failure (false) for each simulated call.
     */
    error SimulationResult(bool[] successArr);

    /**
     * @notice Executes a batch of calls as a single transaction after verifying the delegate's signature and deadline.
     * @param delegate The address of the delegate on whose behalf the calls are executed.
     * @param deadline The expiration timestamp for the signature.
     * @param callsArr An array of `Call` structs to be executed sequentially.
     * @param signature The EIP-712 signature from the delegate authorizing the execution.
     */
    function execute(
        address delegate,
        uint256 deadline,
        Call[] calldata callsArr,
        bytes calldata signature
    ) external payable;

    /**
     * @notice Simulates the execution of a batch of calls and reverts, returning the success status for each call.
     * @param delegate The address of the delegate on whose behalf the calls are simulated.
     * @param deadline The expiration timestamp for the signature.
     * @param callsArr An array of `Call` structs to be simulated sequentially.
     * @param signature The EIP-712 signature from the delegate authorizing the simulation.
     */
    function simulateExecuteAndRevert(
        address delegate,
        uint256 deadline,
        Call[] calldata callsArr,
        bytes calldata signature
    ) external payable;

    /**
     * @notice Retrieves the address of the current delegate.
     * @return delegate The address of the delegate.
     */
    function currentDelegate() external view returns (address);

    /**
     * @notice Computes the hash of the provided calls, which the delegate must sign to authorize execution.
     * @param callsArr An array of `Call` structs to be hashed.
     * @param nonce A unique value used to prevent replay attacks and ensure each hash is distinct.
     * @param deadline The expiration timestamp for the signature.
     * @return hash The `bytes32` hash of the calls, ready for signing.
     */
    function getExecuteHash(
        Call[] calldata callsArr,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);

    /**
     * @notice Computes the hash of an array of calls, which can be used to verify the integrity of the call batch.
     * @param callsArr An array of `Call` structs to be hashed.
     * @return The `bytes32` hash of the entire `callsArr`.
     */
    function getCallsArrHash(Call[] calldata callsArr) external pure returns (bytes32);
}
