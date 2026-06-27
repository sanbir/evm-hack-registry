// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "./QueueLib.sol";
import "./RedBlackTreeLib.sol";

/// @title OrderBookLib - A library for managing an order book in a decentralized exchange
/// @dev This library uses a Red-Black Tree for efficient price level management and a Queue for order management within each price level
library OrderBookLib {
    using RedBlackTreeLib for RedBlackTreeLib.Tree;
    using QueueLib for QueueLib.Queue;
    using QueueLib for QueueLib.Item;

    /// @dev Struct to represent a price point in the order book
    struct PricePoint {
        uint256 orderCount; // Total number of orders at this price point
        uint256 orderValue; // Total value of all orders at this price point
        QueueLib.Queue q; // Queue of order IDs at this price point
    }

    /// @dev Struct to represent an individual order
    struct Order {
        bytes32 id; // Unique identifier for the order
        uint256 price; // Price per unit
        uint256 quantity; // Total quantity of the order
        uint256 availableQuantity; // Remaining unfilled quantity
        uint256 createdAt; // Timestamp of order creation
        uint256 status; // Current status of the order (created or partially filled)
        address traderAddress; // Address of the trader who placed the order
        bool isBuy; // True if it's a buy order, false if it's a sell order
    }

    /// @dev Struct to represent the entire order book
    struct Book {
        RedBlackTreeLib.Tree tree; // Red-Black Tree to store unique price points
        mapping(uint256 => PricePoint) prices; // Mapping of price levels to their corresponding PricePoint
    }

    /// @notice Inserts a new order into the order book
    /// @param b The order book to insert into
    /// @param _orderId The unique identifier of the order
    /// @param _price The price of the order
    /// @param _quantity The quantity of the order
    function insert(Book storage b, bytes32 _orderId, uint256 _price, uint256 _quantity) internal {
        b.tree.insert(_price);

        PricePoint storage pricePoint = b.prices[_price];
        pricePoint.q.push(_orderId);
        pricePoint.orderCount = pricePoint.orderCount + 1;
        pricePoint.orderValue = pricePoint.orderValue + _quantity;
    }

    /// @notice Removes an order from the order book
    /// @param b The order book to remove from
    /// @param _order The order to be removed
    function remove(Book storage b, Order memory _order) internal {
        PricePoint storage price = b.prices[_order.price];
        price.orderCount = price.orderCount - 1;
        price.orderValue = price.orderValue - _order.availableQuantity;
        price.q.remove(_order.id);

        // If this was the last order at this price point, remove the price from the tree
        if (price.q.isEmpty()) {
            b.tree.remove(_order.price);
        }
    }

    /// @notice Updates the quantity of an order at a specific price point
    /// @param b The order book to update
    /// @param _pricePoint The price point of the order to update
    /// @param _quantity The quantity to subtract from the order value
    function update(Book storage b, uint256 _pricePoint, uint256 _quantity) internal {
        PricePoint storage price = b.prices[_pricePoint];
        price.orderValue = price.orderValue - _quantity;
    }

    /// @notice Gets the lowest price in the order book
    /// @param b The order book to query
    /// @return The lowest price in the order book
    function getLowestPrice(Book storage b) internal view returns (uint256) {
        return b.tree.first();
    }

    /// @notice Gets the highest price in the order book
    /// @param b The order book to query
    /// @return The highest price in the order book
    function getHighestPrice(Book storage b) internal view returns (uint256) {
        return b.tree.last();
    }

    /// @notice Gets the three highest or lowest prices in the order book
    /// @param b The order book to query
    /// @param highest If true, get the highest prices; if false, get the lowest prices
    /// @return An array of the three prices
    function get3Prices(Book storage b, bool highest) internal view returns (uint256[3] memory) {
        uint256[3] memory prices;
        uint256 price = highest ? b.tree.last() : b.tree.first();

        // Iterate through the tree to get up to 3 prices
        for (uint256 i = 0; i < 3 && price != 0; i++) {
            prices[i] = price;
            price = highest ? b.tree.prev(price) : b.tree.next(price);
        }

        return prices;
    }

    /// @notice Gets the ID of the next order at a specific price
    /// @param b The order book to query
    /// @param _price The price point to check
    /// @return The ID of the next order at the specified price
    function getNextOrderIdAtPrice(Book storage b, uint256 _price) internal view returns (bytes32) {
        return b.prices[_price].q.first;
    }

    /// @notice Gets the data for a specific price point
    /// @param b The order book to query
    /// @param _pricePoint The price point to get data for
    /// @return The PricePoint struct for the specified price
    function getPricePointData(Book storage b, uint256 _pricePoint) internal view returns (PricePoint storage) {
        return b.prices[_pricePoint];
    }
}
