// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/**
 * @title IBaseModule
 * @notice A foundational interface that establishes a common structure for modules
 * enabling delegated and permissioned actions on behalf of a Gnosis Safe. It defines
 * standard data structures, errors, and events for tracking permissioned approvals.
 */
interface IBaseModule {
    /**
     * @notice A struct to encapsulate the parameters for a token approval operation.
     * @param token The address of the ERC-20 token to approve.
     * @param amount The maximum amount of tokens that can be spent by the spender.
     */
    struct ApprovalParams {
        address token;
        uint256 amount;
    }

    /**
     * @notice Thrown when an external function call initiated by the module fails.
     * @param callName A string identifier for the failed function call, which aids in debugging.
     */
    error CallExecutionFailed(string callName);
    /**
     * @notice Thrown when a delegate attempts an action for which they do not have explicit permission.
     * @param safe The address of the Gnosis Safe that is the subject of the action.
     * @param delegate The address of the user or contract attempting the action.
     * @param permission A string identifier for the permission that was denied.
     */
    error PermissionDenied(address safe, address delegate, string permission);
    /**
     * @notice Thrown when the provided amount does not match the expected amount after applying slippage.
     * @param passedAmount The amount provided by the user or caller.
     * @param amountWithSlippage The calculated amount after applying slippage tolerance.
     */
    error InvalidAmountSlippage(uint256 passedAmount, uint256 amountWithSlippage);

    error NotEnoughValueToWrap(uint256 actualValue, uint256 neededValue);

    /**
     * @notice Emitted to signal that a token approval has been successfully executed by a delegate.
     * @param safe The address of the Gnosis Safe that owns the tokens.
     * @param delegate The address of the user or contract that called the permissioned function.
     * @param token The address of the approved token.
     * @param spender The address of the contract or account that is now authorized to spend the tokens.
     * @param amount The amount for which the approval was granted.
     */
    event PermissionedApprovalExecuted(
        address indexed safe,
        address indexed delegate,
        address token,
        address spender,
        uint256 amount
    );

    event NativeTokensWrapped(address indexed safe, address indexed delegate, uint256 amount);

    event NativeTokensUnwrapped(address indexed safe, address indexed delegate, uint256 amount);

    /**
     * @notice Retrieves the name of the module.
     * @return A string representing the module's name.
     */
    function getModuleName() external view returns (string memory);
}
