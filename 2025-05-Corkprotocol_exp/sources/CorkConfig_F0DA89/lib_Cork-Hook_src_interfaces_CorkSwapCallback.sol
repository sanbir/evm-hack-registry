// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface CorkSwapCallback {
    /**
     * @notice a callback function that will be called by the hook when doing swap, intended use case for flash swap
     * @param sender the address that initiated the swap
     * @param data the data that will be passed to the callback
     * @param paymentAmount the amount of tokens that the user must transfer to the pool manager
     * @param paymentToken the token that the user must transfer  to the pool manager
     * @param poolManager the pool manager to transfer the payment token to
     */
    function CorkCall(
        address sender,
        bytes calldata data,
        uint256 paymentAmount,
        address paymentToken,
        address poolManager
    ) external;
}
