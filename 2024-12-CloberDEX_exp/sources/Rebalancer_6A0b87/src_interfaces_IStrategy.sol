// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {BookId} from "clober-dex/v2-core/libraries/BookId.sol";
import {Tick} from "clober-dex/v2-core/libraries/Tick.sol";

interface IStrategy {
    struct Order {
        Tick tick;
        uint64 rawAmount;
    }

    /**
     * @notice Retrieves the orders for a specified key.
     * @param key The key of the pool.
     * @return ordersA The orders for the first token.
     * @return ordersB The orders for the second token.
     * @dev Clears pool orders if an error occurs and retains current orders if the list is empty.
     */
    function computeOrders(bytes32 key) external view returns (Order[] memory ordersA, Order[] memory ordersB);

    /**
     * @notice Hook that is called after minting.
     * @param sender The address of the sender.
     * @param key The key of the pool.
     * @param mintAmount The amount minted.
     * @param lastTotalSupply The total supply before minting.
     */
    function mintHook(address sender, bytes32 key, uint256 mintAmount, uint256 lastTotalSupply) external;

    /**
     * @notice Hook that is called after burning.
     * @param sender The address of the sender.
     * @param key The key of the pool.
     * @param burnAmount The amount burned.
     * @param lastTotalSupply The total supply before burning.
     */
    function burnHook(address sender, bytes32 key, uint256 burnAmount, uint256 lastTotalSupply) external;

    /**
     * @notice Hook that is called after rebalancing.
     * @param sender The address of the sender.
     * @param key The key of the pool.
     * @param liquidityA The liquidity orders for the first token.
     * @param liquidityB The liquidity orders for the second token.
     */
    function rebalanceHook(address sender, bytes32 key, Order[] memory liquidityA, Order[] memory liquidityB)
        external;
}
