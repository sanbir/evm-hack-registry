// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StorageSlot} from "@summerfi/dependencies/openzeppelin-next/StorageSlot.sol";

import {IArk} from "../interfaces/IArk.sol";
import {ArkData} from "../types/FleetCommanderTypes.sol";
import {StorageSlots} from "./libraries/StorageSlots.sol";

/**
 * @title FleetCommanderCache - Caching System
 * @dev This contract implements a caching mechanism
 *      for efficient asset tracking and operations.
 *
 * Caching System:
 * 1. Purpose: The caching system is designed to optimize gas costs and improve performance
 *    for operations that require frequent access to total assets and ark data.
 *
 * 2. Key Components:
 *    - FleetCommanderCache: A contract that this FleetCommander inherits from, providing
 *      caching functionality.
 *    - Cache Modifiers: 'useDepositCache' and 'useWithdrawCache' are used to manage the
 *      caching lifecycle for deposit and withdrawal operations.
 *
 * 3. Caching Mechanism:
 *    - Before Operation: The cache is populated with current ark data.
 *    - During Operation: The contract uses cached data instead of making repeated calls to arks.
 *    - After Operation: The cache is flushed to ensure data freshness for subsequent operations.
 *
 * 4. Benefits:
 *    - Gas Optimization: Reduces the number of external calls to arks, saving gas.
 *    - Consistency: Ensures that a single operation uses consistent data throughout its execution.
 *
 * 5. Cache Usage:
 *    - Deposit Operations: Uses 'useDepositCache' modifier to cache all ark data.
 *    - Withdrawal Operations: Uses 'useWithdrawCache' modifier to cache data for withdrawable arks.
 *    - Rebalance Operations: Does not use cache as it directly interacts with arks.
 *
 * 6. Cache Management:
 *    - Cache population: Performed by '_getArksData' and '_getWithdrawableArksData' functions.
 *    - Cache flushing: Done by '_flushCache' function after each operation.
 *
 * This caching system is crucial for maintaining efficient operations in the FleetCommander,
 * especially when dealing with multiple arks and frequent asset calculations.
 */
contract FleetCommanderCache {
    using StorageSlot for *;

    /**
     * @dev Checks if the FleetCommander is currently performing a trnsaction that includes a tip
     * @return bool True if collecting tips, false otherwise
     */
    function _isCollectingTip() internal view returns (bool) {
        return StorageSlots.TIP_TAKEN_STORAGE.asBoolean().tload();
    }

    /**
     * @dev Sets the isCollectingTip flag
     * @param value The value to set the flag to
     */
    function _setIsCollectingTip(bool value) internal {
        StorageSlots.TIP_TAKEN_STORAGE.asBoolean().tstore(value);
    }

    /**
     * @dev Calculates the total assets across all arks
     * @param bufferArk The buffer ark instance
     * @return total The sum of total assets across all arks
     * @custom:internal-logic
     * - Checks if total assets are cached
     * - If cached, returns the cached value
     * - If not cached, calculates the sum of total assets across all arks
     * @custom:effects
     * - No state changes
     * @custom:security-considerations
     * - Relies on accurate reporting of total assets by individual arks
     * - Caching mechanism must be properly managed to ensure data freshness
     * - Assumes no changes in total assets throughout the execution of function that use this cache
     */
    function _totalAssets(
        IArk bufferArk
    ) internal view returns (uint256 total) {
        bool isTotalAssetsCached = StorageSlots
            .IS_TOTAL_ASSETS_CACHED_STORAGE
            .asBoolean()
            .tload();
        if (isTotalAssetsCached) {
            return StorageSlots.TOTAL_ASSETS_STORAGE.asUint256().tload();
        }
        return
            _sumTotalAssets(_getAllArks(_getActiveArksAddresses(), bufferArk));
    }

    /**
     * @dev Calculates the total assets of withdrawable arks
     * @param bufferArk The buffer ark instance
     * @return withdrawableTotalAssets The sum of total assets across withdrawable arks
     *  - arks that don't require additional data to be boarded or disembarked from.
     * @custom:internal-logic
     * - Checks if withdrawable total assets are cached
     * - If cached, returns the cached value
     * - If not cached, calculates the sum of total assets across withdrawable arks
     * @custom:effects
     * - No state changes
     * @custom:security-considerations
     * - Relies on accurate reporting of total assets by individual arks
     * - Depends on the correctness of the withdrawableTotalAssets function
     */
    function _withdrawableTotalAssets(
        IArk bufferArk
    ) internal view returns (uint256 withdrawableTotalAssets) {
        bool isWithdrawableTotalAssetsCached = StorageSlots
            .IS_WITHDRAWABLE_ARKS_TOTAL_ASSETS_CACHED_STORAGE
            .asBoolean()
            .tload();
        if (isWithdrawableTotalAssetsCached) {
            return
                StorageSlots
                    .WITHDRAWABLE_ARKS_TOTAL_ASSETS_STORAGE
                    .asUint256()
                    .tload();
        }

        IArk[] memory allArks = _getAllArks(
            _getActiveArksAddresses(),
            bufferArk
        );
        for (uint256 i = 0; i < allArks.length; i++) {
            uint256 withdrawableAssets = IArk(allArks[i])
                .withdrawableTotalAssets();
            if (withdrawableAssets > 0) {
                withdrawableTotalAssets += withdrawableAssets;
            }
        }
    }

    /**
     * @dev Retrieves an array of all Arks, including regular Arks and the buffer Ark
     * @param arks Array of regular ark addresses
     * @param bufferArk The buffer ark instance
     * @return An array of IArk interfaces representing all Arks in the system
     * @custom:internal-logic
     * - Creates a new array with length of regular arks plus one (for buffer ark)
     * - Populates the array with regular arks and appends the buffer ark
     * @custom:effects
     * - No state changes
     * @custom:security-considerations
     * - Ensures the buffer ark is always included at the end of the array
     */
    function _getAllArks(
        address[] memory arks,
        IArk bufferArk
    ) private pure returns (IArk[] memory) {
        IArk[] memory allArks = new IArk[](arks.length + 1);
        for (uint256 i = 0; i < arks.length; i++) {
            allArks[i] = IArk(arks[i]);
        }
        allArks[arks.length] = IArk(bufferArk);
        return allArks;
    }

    /**
     * @dev Calculates the sum of total assets across all provided Arks
     * @param _arks An array of IArk interfaces representing the Arks to sum assets from
     * @return total The sum of total assets across all provided Arks
     * @custom:internal-logic
     * - Iterates through the provided array of Arks
     * - Accumulates the total assets from each Ark
     * @custom:effects
     * - No state changes
     * @custom:security-considerations
     * - Relies on accurate reporting of total assets by individual arks
     * - Vulnerable to integer overflow if total assets become extremely large
     */
    function _sumTotalAssets(
        IArk[] memory _arks
    ) private view returns (uint256 total) {
        for (uint256 i = 0; i < _arks.length; i++) {
            total += _arks[i].totalAssets();
        }
    }

    /**
     * @dev Flushes the cache for all arks and related data
     * @custom:internal-logic
     * - Resets the cached data for all arks and related data
     * @custom:effects
     * - Sets IS_TOTAL_ASSETS_CACHED_STORAGE to false
     * - Sets IS_WITHDRAWABLE_ARKS_TOTAL_ASSETS_CACHED_STORAGE to false
     * - Resets WITHDRAWABLE_ARKS_LENGTH_STORAGE to 0
     * - Resets ARKS_LENGTH_STORAGE to 0
     * @custom:security-considerations
     * - Ensures that the next call to totalAssets or withdrawableTotalAssets recalculates values
     * - Critical for maintaining data freshness and preventing stale cache issues
     * - Flushes cache in case of reentrancy
     * - That also allows efficient testing using Forge (transient storage is persistent during single test)
     */
    function _flushCache() internal {
        StorageSlots.IS_TOTAL_ASSETS_CACHED_STORAGE.asBoolean().tstore(false);
        StorageSlots
            .IS_WITHDRAWABLE_ARKS_TOTAL_ASSETS_CACHED_STORAGE
            .asBoolean()
            .tstore(false);
        StorageSlots.WITHDRAWABLE_ARKS_LENGTH_STORAGE.asUint256().tstore(0);
        StorageSlots.ARKS_LENGTH_STORAGE.asUint256().tstore(0);
    }

    /**
     * @dev Retrieves the data (address, totalAssets) for all arks and the buffer ark
     * @param bufferArk The buffer ark instance
     * @return _arksData An array of ArkData structs containing the ark addresses and their total assets
     * @custom:internal-logic
     * - Initializes data for all arks including the buffer ark
     * - Populates data for regular arks and buffer ark
     * - Caches the total assets and ark data
     * - buffer ark is always at the end of the array
     * @custom:effects
     * - Caches total assets and ark data
     * - Modifies storage slots related to ark data
     * @custom:security-considerations
     * - Relies on accurate reporting of total assets by individual arks
     */
    function _getArksData(
        IArk bufferArk
    ) internal returns (ArkData[] memory _arksData) {
        if (StorageSlots.IS_TOTAL_ASSETS_CACHED_STORAGE.asBoolean().tload()) {
            return _getAllArksDataFromCache();
        }

        address[] memory arks = _getActiveArksAddresses();
        // Initialize data for all arks
        _arksData = new ArkData[](arks.length + 1); // +1 for buffer ark
        uint256 totalAssets = 0;

        // Populate data for regular arks
        for (uint256 i = 0; i < arks.length; i++) {
            uint256 arkAssets = IArk(arks[i]).totalAssets();
            _arksData[i] = ArkData(arks[i], arkAssets);
            totalAssets += arkAssets;
        }

        // Add buffer ark data
        uint256 bufferArkAssets = bufferArk.totalAssets();
        _arksData[arks.length] = ArkData(address(bufferArk), bufferArkAssets);
        totalAssets += bufferArkAssets;

        _cacheAllArksTotalAssets(totalAssets);
        _cacheAllArks(_arksData);
    }

    /**
     * @notice Retrieves a storage slot based on the provided prefix and index
     * @param prefix The prefix for the storage slot
     * @param index The index for the storage slot
     * @return bytes32 The storage slot value
     */
    function _getStorageSlot(
        bytes32 prefix,
        uint256 index
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prefix, index));
    }

    /**
     * @dev Caches the inflow and outflow balances for the specified Ark addresses.
     *      Updates the maximum inflow and outflow balances if they are not set.
     * @param outflowArkAddress The address of the Ark from which the outflow is occurring.
     * @param inflowArkAddress The address of the Ark to which the inflow is occurring.
     * @param amount The amount to be added to both inflow and outflow balances.
     * @return newInflowBalance The updated inflow balance for the inflow Ark.
     * @return newOutflowBalance The updated outflow balance for the outflow Ark.
     * @return maxInflow The maximum inflow balance for the inflow Ark.
     * @return maxOutflow The maximum outflow balance for the outflow Ark.
     */
    function _cacheArkFlow(
        address outflowArkAddress,
        address inflowArkAddress,
        uint256 amount
    )
        internal
        returns (
            uint256 newInflowBalance,
            uint256 newOutflowBalance,
            uint256 maxInflow,
            uint256 maxOutflow
        )
    {
        bytes32 inflowSlot = _getStorageSlot(
            StorageSlots.ARK_INFLOW_BALANCE_STORAGE,
            uint256(uint160(inflowArkAddress))
        );
        bytes32 outflowSlot = _getStorageSlot(
            StorageSlots.ARK_OUTFLOW_BALANCE_STORAGE,
            uint256(uint160(outflowArkAddress))
        );
        bytes32 maxInflowSlot = _getStorageSlot(
            StorageSlots.ARK_MAX_INFLOW_BALANCE_STORAGE,
            uint256(uint160(inflowArkAddress))
        );
        bytes32 maxOutflowSlot = _getStorageSlot(
            StorageSlots.ARK_MAX_OUTFLOW_BALANCE_STORAGE,
            uint256(uint160(outflowArkAddress))
        );

        maxInflow = maxInflowSlot.asUint256().tload();
        maxOutflow = maxOutflowSlot.asUint256().tload();

        if (maxInflow == 0) {
            maxInflow = IArk(inflowArkAddress).maxRebalanceInflow();
            maxInflowSlot.asUint256().tstore(maxInflow);
        }
        if (maxOutflow == 0) {
            maxOutflow = IArk(outflowArkAddress).maxRebalanceOutflow();
            maxOutflowSlot.asUint256().tstore(maxOutflow);
        }

        // Load current balance (if it's the first time, it will be 0)
        newInflowBalance = inflowSlot.asUint256().tload() + amount;
        newOutflowBalance = outflowSlot.asUint256().tload() + amount;

        inflowSlot.asUint256().tstore(newInflowBalance);
        outflowSlot.asUint256().tstore(newOutflowBalance);
    }

    /**
     * @notice Retrieves the data (address, totalAssets) for all withdrawable arks from cache
     * @return arksData An array of ArkData structs containing the ark addresses and their total assets
     */
    function _getWithdrawableArksDataFromCache()
        internal
        view
        returns (ArkData[] memory arksData)
    {
        uint256 arksLength = StorageSlots
            .WITHDRAWABLE_ARKS_LENGTH_STORAGE
            .asUint256()
            .tload();
        arksData = new ArkData[](arksLength);
        for (uint256 i = 0; i < arksLength; i++) {
            address arkAddress = _getStorageSlot(
                StorageSlots.WITHDRAWABLE_ARKS_ADDRESS_ARRAY_STORAGE,
                i
            ).asAddress().tload();
            uint256 totalAssets = _getStorageSlot(
                StorageSlots.WITHDRAWABLE_ARKS_TOTAL_ASSETS_ARRAY_STORAGE,
                i
            ).asUint256().tload();
            arksData[i] = ArkData(arkAddress, totalAssets);
        }
    }

    function _getAllArksDataFromCache()
        internal
        view
        returns (ArkData[] memory arksData)
    {
        uint256 arksLength = StorageSlots
            .ARKS_LENGTH_STORAGE
            .asUint256()
            .tload();
        arksData = new ArkData[](arksLength);
        for (uint256 i = 0; i < arksLength; i++) {
            address arkAddress = _getStorageSlot(
                StorageSlots.ARKS_ADDRESS_ARRAY_STORAGE,
                i
            ).asAddress().tload();
            uint256 totalAssets = _getStorageSlot(
                StorageSlots.ARKS_TOTAL_ASSETS_ARRAY_STORAGE,
                i
            ).asUint256().tload();
            arksData[i] = ArkData(arkAddress, totalAssets);
        }
    }
    /**
     * @notice Caches the data for all arks in the specified storage slots
     * @param arksData The array of ArkData structs containing the ark addresses and their total assets
     * @param totalAssetsPrefix The prefix for the ark total assets storage slot
     * @param addressPrefix The prefix for the ark addresses storage slot
     * @param lengthSlot The storage slot containing the number of arks
     */
    function _cacheArks(
        ArkData[] memory arksData,
        bytes32 totalAssetsPrefix,
        bytes32 addressPrefix,
        bytes32 lengthSlot
    ) internal {
        for (uint256 i = 0; i < arksData.length; i++) {
            _getStorageSlot(totalAssetsPrefix, i).asUint256().tstore(
                arksData[i].totalAssets
            );
            _getStorageSlot(addressPrefix, i).asAddress().tstore(
                arksData[i].arkAddress
            );
        }
        lengthSlot.asUint256().tstore(arksData.length);
    }

    /**
     * @notice Caches the data for all arks in the specified storage slots
     * @param _arksData The array of ArkData structs containing the ark addresses and their total assets
     */
    function _cacheAllArks(ArkData[] memory _arksData) internal {
        _cacheArks(
            _arksData,
            StorageSlots.ARKS_TOTAL_ASSETS_ARRAY_STORAGE,
            StorageSlots.ARKS_ADDRESS_ARRAY_STORAGE,
            StorageSlots.ARKS_LENGTH_STORAGE
        );
    }

    /**
     * @notice Caches the data for all withdrawable arks in the specified storage slots
     * @param _withdrawableArksData The array of ArkData structs containing the ark addresses and their total assets
     */
    function _cacheWithdrawableArksTotalAssetsArray(
        ArkData[] memory _withdrawableArksData
    ) internal {
        _cacheArks(
            _withdrawableArksData,
            StorageSlots.WITHDRAWABLE_ARKS_TOTAL_ASSETS_ARRAY_STORAGE,
            StorageSlots.WITHDRAWABLE_ARKS_ADDRESS_ARRAY_STORAGE,
            StorageSlots.WITHDRAWABLE_ARKS_LENGTH_STORAGE
        );
    }

    /**
     * @dev Retrieves and processes data for withdrawable arks
     * @param bufferArk The buffer ark instance
     * @custom:internal-logic
     * - Fetches data for all arks using _getArksData
     * - Filters arks based on withdrawability
     * - Accumulates total assets of withdrawable arks
     * - Resizes the array to remove empty slots
     * - Sorts the withdrawable arks by total assets
     * - Caches the processed data
     * - checks if the arks are cached, if yes skips the rest of the function
     * - cache check is important for nested calls e.g. withdraw (withdrawFromArks)
     * @custom:effects
     * - Modifies storage by caching withdrawable arks data
     * - Updates the total assets of withdrawable arks in storage
     * @custom:security-considerations
     * - Assumes the withdrawableTotalAssets function is correctly implemented by Ark contracts
     * - Uses assembly for array resizing, which bypasses Solidity's safety checks
     * - Relies on the correctness of _getArksData, _cacheWithdrawableArksTotalAssets,
     *   _sortArkDataByTotalAssets, and _cacheWithdrawableArksTotalAssetsArray functions
     */
    function _getWithdrawableArksData(IArk bufferArk) internal {
        if (
            StorageSlots
                .IS_WITHDRAWABLE_ARKS_TOTAL_ASSETS_CACHED_STORAGE
                .asBoolean()
                .tload()
        ) {
            return;
        }
        ArkData[] memory _arksData = _getArksData(bufferArk);
        // Initialize data for withdrawable arks
        ArkData[] memory _withdrawableArksData = new ArkData[](
            _arksData.length
        );
        uint256 withdrawableTotalAssets = 0;
        uint256 withdrawableCount = 0;

        // Populate data for withdrawable arks
        for (uint256 i = 0; i < _arksData.length; i++) {
            uint256 withdrawableAssets = IArk(_arksData[i].arkAddress)
                .withdrawableTotalAssets();
            if (withdrawableAssets > 0) {
                // overwrite the ArkData struct with the withdrawable assets
                _withdrawableArksData[withdrawableCount] = ArkData(
                    _arksData[i].arkAddress,
                    withdrawableAssets
                );

                withdrawableTotalAssets += withdrawableAssets;
                withdrawableCount++;
            }
        }

        // Resize _withdrawableArksData array to remove empty slots
        assembly {
            mstore(_withdrawableArksData, withdrawableCount)
        }
        _cacheWithdrawableArksTotalAssets(withdrawableTotalAssets);
        _sortArkDataByTotalAssets(_withdrawableArksData);
        _cacheWithdrawableArksTotalAssetsArray(_withdrawableArksData);
    }

    /**
     * @notice Caches the total assets for all arks in the specified storage slot
     * @param totalAssets The total assets to cache
     */
    function _cacheAllArksTotalAssets(uint256 totalAssets) internal {
        StorageSlots.TOTAL_ASSETS_STORAGE.asUint256().tstore(totalAssets);
        StorageSlots.IS_TOTAL_ASSETS_CACHED_STORAGE.asBoolean().tstore(true);
    }

    /**
     * @notice Caches the total assets for all withdrawable arks in the specified storage slot
     * @param withdrawableTotalAssets The total assets to cache
     */
    function _cacheWithdrawableArksTotalAssets(
        uint256 withdrawableTotalAssets
    ) internal {
        StorageSlots.WITHDRAWABLE_ARKS_TOTAL_ASSETS_STORAGE.asUint256().tstore(
            withdrawableTotalAssets
        );
        StorageSlots
            .IS_WITHDRAWABLE_ARKS_TOTAL_ASSETS_CACHED_STORAGE
            .asBoolean()
            .tstore(true);
    }

    /**
     * @dev Sorts the ArkData structs based on their total assets in ascending order
     * @param arkDataArray An array of ArkData structs to be sorted
     * @custom:internal-logic
     * - Implements a simple bubble sort algorithm
     * - Compares adjacent elements and swaps them if they are in the wrong order
     * - Continues until no more swaps are needed
     * @custom:effects
     * - Modifies the input array in-place, sorting it by totalAssets
     * @custom:security-considerations
     * - Time complexity is O(n^2), which may be inefficient for large arrays
     * - Assumes that the totalAssets values fit within uint256 and won't overflow during comparisons
     */
    function _sortArkDataByTotalAssets(
        ArkData[] memory arkDataArray
    ) internal pure {
        for (uint256 i = 0; i < arkDataArray.length; i++) {
            for (uint256 j = i + 1; j < arkDataArray.length; j++) {
                if (arkDataArray[i].totalAssets > arkDataArray[j].totalAssets) {
                    (arkDataArray[i], arkDataArray[j]) = (
                        arkDataArray[j],
                        arkDataArray[i]
                    );
                }
            }
        }
    }

    /**
     * @notice Returns an array of addresses for all currently active Arks in the fleet
     * @dev This is an abstract internal function that must be implemented by the FleetCommander contract
     *      It serves as a critical component in the caching system for efficient ark management
     *
     * @return address[] An array containing the addresses of all active Arks
     *
     * @custom:purpose
     * - Provides the foundation for the caching system by identifying which Arks are currently active
     * - Used by _getArksData and _getWithdrawableArksData to populate cache data
     * - Essential for operations that need to iterate over or manage all active Arks
     * - Defined as virtual to be overridden by the FleetCommander contract and avoid calling it before it's required
     *
     * @custom:implementation-notes
     * - Must be implemented by the inheriting FleetCommander contract
     * - Should return a fresh array of addresses each time it's called
     * - Buffer Ark should NOT be included in this list (it's handled separately)
     * - Only truly active and operational Arks should be included
     *
     * @custom:related-functions
     * - _getArksData: Uses this function to get data for all active Arks
     * - _getWithdrawableArksData: Uses this function to identify withdrawable Arks
     * - _getAllArks: Combines these addresses with the buffer Ark
     */
    function _getActiveArksAddresses()
        internal
        view
        virtual
        returns (address[] memory)
    {}
}
