// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.22;

/**
 * @dev Library with global errors for Mure
 * @author Mure
 */
library MureErrors {
    /**
     * @dev thrown when address is invalid, eg: zero address
     */
    error InvalidAddress(address addr);

    /**
     * @dev thrown when a signature has expired before verification
     */
    error SignatureExpired();

    /**
     * @dev thrown when any restricted operation is performed by an unauthorized entity
     */
    error Unauthorized();

    /**
     * @dev thrown when address is not a valid delegate
     */
    error InvalidDelegate();

    /**
     * @dev thrown when pool with given parameters is not found
     */
    error PoolNotFound();

    /**
     * @dev thrown when fee is invalid
     */
    error InvalidFee();
}
