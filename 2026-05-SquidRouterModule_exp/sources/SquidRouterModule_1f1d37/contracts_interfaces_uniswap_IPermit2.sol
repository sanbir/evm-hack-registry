// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

/**
 * @title IPermit2
 * @notice Interface for the Uniswap Permit2 contract, enabling efficient token approvals via a single contract.
 */
interface IPermit2 {
    /**
     * @notice Approve a spender to spend a token with an optional expiration.
     * @param token Address of the token to approve.
     * @param spender Address allowed to spend the token.
     * @param amount Maximum amount the spender can transfer.
     * @param expiration Block timestamp after which the approval expires.
     */
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
