// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.22;

/**
 * @dev Structure of a pool
 */
struct PoolState {
    uint112 totalCollected;
    uint112 poolSize;
    uint16 flags;
    uint16 depositors;
    uint32 endTime; // uint32 => year 2106
    address currency;
    address custodian;
    address signer;
}

/**
 * @dev Interface for pool information like its state and existence
 * @author Mure
 */
interface PoolMetadata {
    function isPoolActive(string calldata poolName) external view returns (bool);

    function poolExists(string calldata pool) external view returns (bool);

    function poolState(string calldata poolName) external view returns (PoolState memory);

    function withdrawableAmount(string calldata poolName) external view returns (uint112);
}
