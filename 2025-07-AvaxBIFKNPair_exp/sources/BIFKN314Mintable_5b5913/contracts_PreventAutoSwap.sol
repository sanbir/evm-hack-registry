// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * @dev Contract module that helps prevent automatic swapping within a function call
 * for specific callers, allowing for finer control over when swapping should be prevented.
 *
 * This version uses a mapping to track the prevention status for each caller,
 * making it context-sensitive and allowing for certain operations to not affect others.
 */
abstract contract PreventAutoSwap {
    mapping(address => bool) private _autoSwapPreventedFor;

    /**
     * @dev Thrown when an operation tries to perform an auto-swap and it is prevented for the caller.
     */
    error AutoSwapPrevented();

    /**
     * @dev Prevents auto-swap for the caller of the function this modifier is applied to.
     * This approach allows differentiating between various operations and callers,
     * giving more control over the swapping mechanism.
     */
    modifier preventAutoSwap() {
        _preventAutoSwapBefore();
        _;
        _preventAutoSwapAfter();
    }

    /**
     * @dev Prevents automatic swapping before executing a transaction.
     * If the msg.sender has already prevented auto swapping, it reverts with an `AutoSwapPrevented` error.
     * Otherwise, it marks the transaction origin as prevented for auto swapping.
     */
    function _preventAutoSwapBefore() private {
        if (_autoSwapPreventedFor[msg.sender]) {
            revert AutoSwapPrevented();
        }
        _autoSwapPreventedFor[msg.sender] = true;
    }

    /**
     * @dev Internal function to prevent auto swap after a transaction.
     * @notice This function sets the `_autoSwapPreventedFor` mapping value for the `msg.sender` address to `false`.
     * @notice Auto swap refers to an automatic swapping of tokens that may occur during a transaction.
     * @notice By calling this function, the auto swap is prevented for the `msg.sender` address.
     * @notice This function is private and can only be called from within the contract.
     */
    function _preventAutoSwapAfter() private {
        _autoSwapPreventedFor[msg.sender] = false;
    }

    /**
     * @dev Returns true if auto swap is currently prevented for the caller.
     */
    function _autoSwapIsPrevented() internal view returns (bool) {
        return _autoSwapPreventedFor[msg.sender];
    }
}
