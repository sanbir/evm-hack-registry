// SPDX-License-Identifier: BSL-1.1

// @author samthebuilder.eth

pragma solidity ^0.8.26;

/**
 * @title IBeforeHook
 * @notice Interface for a hook that is called before a transfer is executed.
 */
interface IBeforeHook {
    /**
     * @notice Hook that is called before a transfer is executed. Hook should revert if the transfer should not be executed.
     * @param sender The address that initiates the transfer.
     * @param receiver The address that receives the transfer.
     * @param tokenOutAmount The amount of tokens that are transferred.
     * @param tokenOutAddress The address of the token that is transferred.
     * @param yd ID of the extension.
     * @param payload Any arbitrary payload attached to the transfer.
     * @return Any arbitrary uint256 value.
     */
    function beforeHook(
        address sender,
        address receiver,
        uint256 tokenOutAmount,
        address tokenOutAddress,
        uint256 yd,
        bytes[] calldata payload
    ) external view returns (uint256);
}
