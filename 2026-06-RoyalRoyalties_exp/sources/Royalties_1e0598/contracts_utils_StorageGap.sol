//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.2;

/**
 * @title StorageGap
 * @author Royal
 * @dev Adds a gap in the storage layout of a contract.
 *
 *  This can be used to allow more flexibility in the upgrades of a proxy-upgradeable contract.
 */
abstract contract StorageGap {
    uint256[1_000_000] private __gap;
}
