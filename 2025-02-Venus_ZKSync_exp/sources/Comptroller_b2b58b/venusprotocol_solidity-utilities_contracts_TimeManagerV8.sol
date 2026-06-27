// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { SECONDS_PER_YEAR } from "./constants.sol";

abstract contract TimeManagerV8 {
    /// @notice Stores blocksPerYear if isTimeBased is true else secondsPerYear is stored
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable blocksOrSecondsPerYear;

    /// @notice Acknowledges if a contract is time based or not
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool public immutable isTimeBased;

    /// @notice Stores the current block timestamp or block number depending on isTimeBased
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    function() view returns (uint256) private immutable _getCurrentSlot;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;

    /// @notice Thrown when blocks per year is invalid
    error InvalidBlocksPerYear();

    /// @notice Thrown when time based but blocks per year is provided
    error InvalidTimeBasedConfiguration();

    /**
     * @param timeBased_ A boolean indicating whether the contract is based on time or block
     * If timeBased is true than blocksPerYear_ param is ignored as blocksOrSecondsPerYear is set to SECONDS_PER_YEAR
     * @param blocksPerYear_ The number of blocks per year
     * @custom:error InvalidBlocksPerYear is thrown if blocksPerYear entered is zero and timeBased is false
     * @custom:error InvalidTimeBasedConfiguration is thrown if blocksPerYear entered is non zero and timeBased is true
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(bool timeBased_, uint256 blocksPerYear_) {
        if (!timeBased_ && blocksPerYear_ == 0) {
            revert InvalidBlocksPerYear();
        }

        if (timeBased_ && blocksPerYear_ != 0) {
            revert InvalidTimeBasedConfiguration();
        }

        isTimeBased = timeBased_;
        blocksOrSecondsPerYear = timeBased_ ? SECONDS_PER_YEAR : blocksPerYear_;
        _getCurrentSlot = timeBased_ ? _getBlockTimestamp : _getBlockNumber;
    }

    /**
     * @dev Function to simply retrieve block number or block timestamp
     * @return Current block number or block timestamp
     */
    function getBlockNumberOrTimestamp() public view virtual returns (uint256) {
        return _getCurrentSlot();
    }

    /**
     * @dev Returns the current timestamp in seconds
     * @return The current timestamp
     */
    function _getBlockTimestamp() private view returns (uint256) {
        return block.timestamp;
    }

    /**
     * @dev Returns the current block number
     * @return The current block number
     */
    function _getBlockNumber() private view returns (uint256) {
        return block.number;
    }
}
