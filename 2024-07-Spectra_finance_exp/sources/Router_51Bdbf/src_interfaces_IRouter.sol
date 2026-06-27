// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.20;

// https://github.com/Uniswap/universal-router/blob/main/contracts/interfaces/IUniversalRouter.sol

interface IRouter {
    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when attempting to execute commands and an incorrect number of inputs are provided
    error LengthMismatch();

    /// @notice Thrown when onFlashloan() is called directly, rather than through a command execution
    error DirectOnFlashloanCall();

    /// @notice Thrown when onFlashloan() is called by an address other than flashloan lender
    error UnauthorizedOnFlashloanCaller();

    /// @notice Thrown when an address other than msgSender and Router reenters execute()
    error UnauthorizedReentrantCall();

    /**
     * @dev Setter for the router utility contract
     * @param _routerUtil The new address of the router utility contract
     */
    function setRouterUtil(address _routerUtil) external;

    /**
     * @dev Executes encoded commands along with provided inputs
     * Reverts if deadline has expired
     * @param _commands A set of concatenated commands, each 1 byte in length
     * @param _inputs An array of byte strings containing ABI-encoded inputs for each command
     * @param _deadline The deadline by which the transaction must be executed
     */
    function execute(
        bytes calldata _commands,
        bytes[] calldata _inputs,
        uint256 _deadline
    ) external payable;

    /**
     * @dev Executes encoded commands along with provided inputs
     * @param _commands A set of concatenated commands, each 1 byte in length
     * @param _inputs An array of byte strings containing ABI-encoded inputs for each command
     */
    function execute(bytes calldata _commands, bytes[] calldata _inputs) external payable;

    /**
     * @dev Simulates encoded commands along with provided inputs and returns the resulting rate
     * The rate is calculated as follows: rate = ray_unit * output_token_amount / input_token_amount
     * @param _commands A set of concatenated commands, each 1 byte in length
     * @param _inputs An array of byte strings containing ABI-encoded inputs for each command
     * @return The preview rate value, which represents the amount of output token obtained at the end of execution
     * for each wei of input token spent at the start of execution, multiplied by 1 ray unit.
     */
    function previewRate(
        bytes calldata _commands,
        bytes[] calldata _inputs
    ) external view returns (uint256);

    /**
     * @dev Simulates encoded commands along with provided inputs and returns the resulting spot rate.
     * As opposed to `previewRate`, spot exchange rates will be used for swaps. Additionally for all commands,
     * input amounts are disregarded, and one unit of the token of interest is used instead.
     * @param _commands A set of concatenated commands, each 1 byte in length
     * @param _inputs An array of byte strings containing ABI-encoded inputs for each command
     * @return The preview spot rate value, which represents the amount of output token obtained at the end of execution
     * for each wei of input token spent at the start of execution, multiplied by 1 ray unit.
     */

    function previewSpotRate(
        bytes calldata _commands,
        bytes[] calldata _inputs
    ) external view returns (uint256);
}
