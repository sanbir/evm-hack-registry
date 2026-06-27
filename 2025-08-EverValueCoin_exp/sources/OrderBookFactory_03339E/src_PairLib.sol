// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./OrderBookLib.sol";

/// @title PairLib - A library for managing trading pairs and order books
/// @notice This library provides functionality for creating, canceling, and matching orders in a decentralized exchange
/// @dev This library uses OpenZeppelin's SafeERC20 for secure token transfers
library PairLib {
    using SafeERC20 for IERC20;
    using OrderBookLib for OrderBookLib.Order;
    using OrderBookLib for OrderBookLib.Book;
    using OrderBookLib for OrderBookLib.PricePoint;
    /// @notice Thrown when an order doesn't belong to the current trader

    error PL__OrderDoesNotBelongToCurrentTrader();
    /// @notice Thrown when an order ID does not exist
    error PL__OrderIdDoesNotExist();
    /// @notice Thrown when an amount is invalid
    error PL__InvalidPaymentAmount();
    /// @notice Thrown when an order ID already exists
    error PL__OrderIdAlreadyExists();
    /// @notice Thrown when an invalid price is provided
    /// @param price The invalid price
    error PL__InvalidPrice(uint256 price);
    /// @notice Thrown when an invalid quantity is provided
    /// @param quantity The invalid quantity
    error PL__InvalidQuantity(uint256 quantity);
    /// @notice Thrown when attempting to interact with a disabled pair
    error PL__PairDisabled();

    /// @dev Precision factor for price calculations
    uint256 private constant PRECISION = 1e18;
    /// @dev Maximum number of orders that can be filled in a single transaction
    uint256 private constant MAX_NUMBER_ORDERS_FILLED = 1500; // A new order can take this orders at max
    /// @dev Constant representing the status of a newly created order
    uint256 private constant ORDER_CREATED = 1;
    /// @dev Constant representing the status of a partially filled order
    uint256 private constant ORDER_PARTIALLY_FILLED = 2;

    /// @dev Structure to keep track of a trader's orders
    /// @notice This structure maintains an efficient record of all orders belonging to a specific trader
    struct TraderOrderRegistry {
        /// @dev Array of order IDs belonging to the trader
        bytes32[] orderIds;
        /// @dev Mapping from order ID to its index in the orderIds array
        /// @notice This allows for O(1) removal of orders from the registry
        mapping(bytes32 => uint256) index;
    }

    /// @dev Struct representing a trader's balance in a trading pair
    /// @member baseTokenBalance The balance of the base token for the trader
    /// @member quoteTokenBalance The balance of the quote token for the trader
    struct TraderBalance {
        uint256 baseTokenBalance;
        uint256 quoteTokenBalance;
    }

    /// @dev Main structure representing a trading pair
    /// @notice This structure encapsulates all data and functionality related to a specific trading pair
    struct Pair {
        /// @dev The price of the last executed trade for this pair
        uint256 lastTradePrice;
        /// @dev The fee percentage for trades in this pair (in basis points)
        uint256 fee;
        /// @dev The address of the base token in the pair (e.g., ETH in ETH/USDT)
        address baseToken;
        /// @dev The address of the quote token in the pair (e.g., USDT in ETH/USDT)
        address quoteToken;
        /// @dev The address where trading fees are sent
        address feeAddress;
        /// @dev Flag indicating whether trading is enabled for this pair
        bool enabled;
        /// @dev Order book for buy orders
        OrderBookLib.Book buyOrders;
        /// @dev Order book for sell orders
        OrderBookLib.Book sellOrders;
        /// @dev Mapping of trader addresses to their order registries
        /// @notice This allows quick access to all orders of a specific trader
        mapping(address => TraderOrderRegistry) traderOrderRegistry;
        /// @dev Mapping of order IDs to Order structures
        /// @notice This allows O(1) access to any order details given its ID
        mapping(bytes32 => OrderBookLib.Order) orders;
        /// @dev Mapping to store trader balances for each trading pair
        /// @notice This mapping is accessed using the trader's address as the key
        mapping(address => TraderBalance) traderBalances;
    }

    /// @notice Emitted when a new order is created
    /// @param id The unique identifier of the created order
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param trader The address of the trader who created the order
    event OrderCreated(bytes32 indexed id, address indexed baseToken, address indexed quoteToken, address trader);

    /// @notice Emitted when an existing order is canceled
    /// @param id The unique identifier of the canceled order
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param trader The address of the trader who canceled the order
    event OrderCanceled(bytes32 indexed id, address indexed baseToken, address indexed quoteToken, address trader);

    /// @notice Emitted when an order is completely filled (executed)
    /// @param id The unique identifier of the filled order
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param trader The address of the trader whose order was filled
    event OrderFilled(bytes32 indexed id, address indexed baseToken, address indexed quoteToken, address trader);

    /// @notice Emitted when an order is partially filled (partially executed)
    /// @param id The unique identifier of the partially filled order
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param trader The address of the trader whose order was partially filled
    event OrderPartiallyFilled(
        bytes32 indexed id, address indexed baseToken, address indexed quoteToken, address trader
    );

    /// @notice Emitted when the fee for a trading pair is changed
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param newFee The new fee value for the trading pair
    event PairFeeChanged(address indexed baseToken, address indexed quoteToken, uint256 newFee);

    /// @notice Changes the fee for a trading pair
    /// @dev This function can only be called internally, typically by the contract owner
    /// @param pair The storage reference to the Pair struct
    /// @param newFee The new fee to be set (in basis points)
    function changePairFee(Pair storage pair, uint256 newFee) internal {
        pair.fee = newFee;
        emit PairFeeChanged(pair.baseToken, pair.quoteToken, newFee);
    }

    /// @notice Allows a trader to withdraw their balance from a trading pair
    /// @dev This function updates the trader's balance and transfers tokens to their address
    /// @param pair The storage reference to the Pair struct containing trader balances
    /// @param traderAddress The address of the trader withdrawing their balance
    /// @param baseTokenWithdrawal if true withdraws base token's balance, if false withdraws quote token's balance
    function withdrawBalance(Pair storage pair, address traderAddress, bool baseTokenWithdrawal) internal {
        // Retrieve the trader's current balances
        (uint256 withdrawBalance, IERC20 withdrawToken) = baseTokenWithdrawal
            ? (pair.traderBalances[traderAddress].baseTokenBalance, IERC20(pair.baseToken))
            : (pair.traderBalances[traderAddress].quoteTokenBalance, IERC20(pair.quoteToken));

        // Withdraw token balance if available
        if (withdrawBalance > 0) {
            // Reset the token balance to prevent reentrancy
            if (baseTokenWithdrawal) {
                pair.traderBalances[traderAddress].baseTokenBalance = 0;
            } else {
                pair.traderBalances[traderAddress].quoteTokenBalance = 0;
            }
            // Transfer the tokens to the trader
            IERC20(withdrawToken).safeTransfer(traderAddress, withdrawBalance);
        }
    }

    /// @notice Adds a new buy order to the order book
    /// @dev This function checks if the pair is enabled before creating the order
    /// @param pair The storage reference to the Pair struct
    /// @param _price The price at which the buy order is placed
    /// @param _quantity The quantity of base tokens to buy
    /// @param timestamp The timestamp of the order creation
    function addBuyOrder(Pair storage pair, uint256 _price, uint256 _quantity, uint256 timestamp) internal {
        if (!pair.enabled) revert PL__PairDisabled();
        createOrder(pair, true, _price, _quantity, timestamp);
    }

    /// @notice Adds a new sell order to the order book
    /// @dev This function checks if the pair is enabled before creating the order
    /// @param pair The storage reference to the Pair struct
    /// @param _price The price at which the sell order is placed
    /// @param _quantity The quantity of base tokens to sell
    /// @param timestamp The timestamp of the order creation
    function addSellOrder(Pair storage pair, uint256 _price, uint256 _quantity, uint256 timestamp) internal {
        if (!pair.enabled) revert PL__PairDisabled();
        createOrder(pair, false, _price, _quantity, timestamp);
    }

    /// @notice Cancels an existing order in the order book
    /// @dev This function can only be called by the original order creator
    /// @param pair The storage reference to the Pair struct
    /// @param _orderId The unique identifier of the order to be canceled
    function cancelOrder(Pair storage pair, bytes32 _orderId) internal {
        // Check if the order exists
        if (!orderExists(pair, _orderId)) revert PL__OrderIdDoesNotExist();

        // Ensure the caller is the original order creator
        if (pair.orders[_orderId].traderAddress != msg.sender) revert PL__OrderDoesNotBelongToCurrentTrader();

        // Retrieve the order details
        OrderBookLib.Order memory removedOrder = pair.orders[_orderId];

        // Determine the token and remaining funds to be returned
        // For buy orders: return quote tokens
        // For sell orders: return base tokens
        (IERC20 token, uint256 remainingFunds) = removedOrder.isBuy
            ? (IERC20(pair.quoteToken), removedOrder.availableQuantity * removedOrder.price / PRECISION)
            : (IERC20(pair.baseToken), removedOrder.availableQuantity);

        // Remove the order from the order book and related data structures
        removeOrder(pair, removedOrder);

        // Transfer the remaining funds back to the trader
        token.safeTransfer(removedOrder.traderAddress, remainingFunds);

        // Emit an event to signal the order cancellation
        emit OrderCanceled(_orderId, pair.baseToken, pair.quoteToken, msg.sender);
    }

    /// @notice Removes an order from a trader's order registry
    /// @dev This function uses an efficient O(1) removal technique
    /// @param pair The storage reference to the Pair struct
    /// @param _orderId The unique identifier of the order to be removed
    /// @param traderAddress The address of the trader whose order is being removed
    function removeFromTraderOrders(Pair storage pair, bytes32 _orderId, address traderAddress) private {
        // Get a reference to the trader's order registry
        TraderOrderRegistry storage to = pair.traderOrderRegistry[traderAddress];

        // Get the index of the order to be deleted and the index of the last order
        uint256 deleteIndex = to.index[_orderId];
        uint256 lastIndex = to.orderIds.length - 1;

        // If the order to be deleted is not the last one, replace it with the last order
        if (deleteIndex != lastIndex) {
            to.orderIds[deleteIndex] = to.orderIds[lastIndex];
            // Update the index of the moved order
            to.index[to.orderIds[lastIndex]] = deleteIndex;
        }

        // Remove the last element from the array
        to.orderIds.pop();
        // Remove the order's index from the mapping
        delete to.index[_orderId];
    }

    /// @notice Adds a new order to the order book
    /// @dev This function handles the creation and insertion of a new order into the book
    /// @param pair The storage reference to the Pair struct
    /// @param newOrder The new order to be added to the book
    function addOrder(Pair storage pair, OrderBookLib.Order memory newOrder) private {
        // Get the trader's order registry and add the new order
        TraderOrderRegistry storage registry = pair.traderOrderRegistry[msg.sender];
        registry.orderIds.push(newOrder.id);
        registry.index[newOrder.id] = registry.orderIds.length - 1;

        // Determine the token to collect, the amount to transfer, and the order book to use
        (IERC20 token, uint256 transferAmount, OrderBookLib.Book storage book) = newOrder.isBuy
            ? (IERC20(pair.quoteToken), newOrder.quantity * newOrder.price / PRECISION, pair.buyOrders)
            : (IERC20(pair.baseToken), newOrder.quantity, pair.sellOrders);

        // Validate non-zero payment
        if (transferAmount == 0) {
            revert PL__InvalidPaymentAmount();
        }

        // Transfer the required funds from the trader to the contract
        token.safeTransferFrom(msg.sender, address(this), transferAmount);

        // Insert the new order into the appropriate order book
        book.insert(newOrder.id, newOrder.price, newOrder.quantity);

        // Store the order details in the pair's orders mapping
        pair.orders[newOrder.id] = newOrder;

        // Emit an event to signal the creation of a new order
        emit OrderCreated(newOrder.id, pair.baseToken, pair.quoteToken, msg.sender);
    }

    /// @notice Removes an order from the order book and related data structures
    /// @dev This function handles the complete removal of an order, including from the order book, trader's registry, and order details
    /// @param pair The storage reference to the Pair struct
    /// @param order The order to be removed
    function removeOrder(Pair storage pair, OrderBookLib.Order memory order) private {
        // Remove the order from the appropriate order book (buy or sell)
        (order.isBuy ? pair.buyOrders : pair.sellOrders).remove(order);

        // Remove the order from the trader's order registry
        removeFromTraderOrders(pair, order.id, order.traderAddress);

        // Delete the order details from the pair's orders mapping
        delete pair.orders[order.id];
    }

    /// @notice Fills a matched order completely
    /// @dev This function handles the token transfers, fee calculation, and order updates when a match is found
    /// @param pair The storage reference to the Pair struct
    /// @param matchedOrder The storage reference to the existing order that is being filled
    /// @param takerOrder The memory reference to the new order that is filling the matched order
    function fillOrder(Pair storage pair, OrderBookLib.Order storage matchedOrder, OrderBookLib.Order memory takerOrder)
        private
    {
        // Update the last trade price for the pair
        pair.lastTradePrice = matchedOrder.price;

        // Determine which tokens are being received and sent by the taker, and their amounts
        (IERC20 takerReceiveToken, uint256 takerReceiveAmount, IERC20 takerSendToken, uint256 takerSendAmount) =
        takerOrder.isBuy
            ? (
                IERC20(pair.baseToken),
                matchedOrder.availableQuantity,
                IERC20(pair.quoteToken),
                matchedOrder.availableQuantity * matchedOrder.price / PRECISION
            )
            : (
                IERC20(pair.quoteToken),
                matchedOrder.availableQuantity * matchedOrder.price / PRECISION,
                IERC20(pair.baseToken),
                matchedOrder.availableQuantity
            );

        // Validate non-zero payment
        if (takerSendAmount == 0 || takerReceiveAmount == 0) {
            revert PL__InvalidPaymentAmount();
        }

        // Calculate the fee based on the amount the taker receives
        /// @dev The fee is calculated in basis points (1/100 of a percent)
        uint256 fee = (takerReceiveAmount * pair.fee) / 10000;
        uint256 takerReceiveAmountAfterFee = takerReceiveAmount - fee;

        /// @notice Update the token balances of the maker based on the order type
        /// @dev For buy orders, update quote token balance; for sell orders, update base token balance
        takerSendToken.safeTransferFrom(msg.sender, address(this), takerSendAmount);
        if (takerOrder.isBuy) {
            // If it's a buy order, update the quote token balance of the maker (seller)
            pair.traderBalances[matchedOrder.traderAddress].quoteTokenBalance += takerSendAmount;
        } else {
            // If it's a sell order, update the base token balance of the maker (buyer)

            pair.traderBalances[matchedOrder.traderAddress].baseTokenBalance += takerSendAmount;
        }
        takerReceiveToken.safeTransfer(msg.sender, takerReceiveAmountAfterFee);

        // Transfer the fee to the designated fee address, if set
        if (pair.feeAddress != address(0)) {
            takerReceiveToken.safeTransfer(pair.feeAddress, fee);
        }

        // Update the taker's order quantity
        takerOrder.quantity -= matchedOrder.availableQuantity;
        takerOrder.availableQuantity -= matchedOrder.availableQuantity;

        // Emit events for the filled orders
        emit OrderFilled(matchedOrder.id, pair.baseToken, pair.quoteToken, matchedOrder.traderAddress);

        // Remove the fully matched order from the order book
        removeOrder(pair, matchedOrder);
    }

    /// @notice Partially fills a matched order
    /// @dev This function handles the token transfers, fee calculation, and order updates when a partial match is found
    /// @param pair The storage reference to the Pair struct
    /// @param matchedOrder The storage reference to the existing order that is being partially filled
    /// @param takerOrder The memory reference to the new order that is partially filling the matched order
    function partiallyFillOrder(
        Pair storage pair,
        OrderBookLib.Order storage matchedOrder,
        OrderBookLib.Order memory takerOrder
    ) private {

        // Determine which tokens are being received and sent by the taker, and their amounts
        /// @dev The calculation depends on whether the taker order is a buy or sell order
        (IERC20 takerReceiveToken, uint256 takerReceiveAmount, IERC20 takerSendToken, uint256 takerSendAmount) =
        takerOrder.isBuy
            ? (
                IERC20(pair.baseToken),
                takerOrder.quantity,
                IERC20(pair.quoteToken),
                takerOrder.quantity * matchedOrder.price / PRECISION
            )
            : (
                IERC20(pair.quoteToken),
                takerOrder.quantity * matchedOrder.price / PRECISION,
                IERC20(pair.baseToken),
                takerOrder.quantity
            );

        // Validate non-zero payment
        if (takerSendAmount == 0 || takerReceiveAmount == 0) {
            // Set quantity to 0 as to skip the remaining amount, and consider the taker order as filled
            takerOrder.quantity = 0;
            takerOrder.availableQuantity = 0;
            return;
        }

        // Update the last trade price for the pair
        pair.lastTradePrice = matchedOrder.price;

        // Calculate fee (on the buy token amount, which is what the taker receives)
        /// @dev The fee is calculated in basis points (1/100 of a percent)
        uint256 fee = (takerReceiveAmount * pair.fee) / 10000;
        uint256 takerReceiveAmountAfterFee = takerReceiveAmount - fee;

        /// @notice Update the token balances of the maker based on the order type
        /// @dev For buy orders, update quote token balance; for sell orders, update base token balance
        takerSendToken.safeTransferFrom(msg.sender, address(this), takerSendAmount);
        if (takerOrder.isBuy) {
            // If it's a buy order, update the quote token balance of the maker (seller)
            pair.traderBalances[matchedOrder.traderAddress].quoteTokenBalance += takerSendAmount;
        } else {
            // If it's a sell order, update the base token balance of the maker (buyer)
            pair.traderBalances[matchedOrder.traderAddress].baseTokenBalance += takerSendAmount;
        }

        // Transfer buy tokens from maker to taker (minus fee)
        takerReceiveToken.safeTransfer(msg.sender, takerReceiveAmountAfterFee);

        // Transfer fee to fee address if set, otherwise it stays in the contract
        if (pair.feeAddress != address(0)) {
            takerReceiveToken.safeTransfer(pair.feeAddress, fee);
        }

        // Update the matched order by reducing its available quantity
        matchedOrder.availableQuantity = matchedOrder.availableQuantity - takerOrder.quantity;
        matchedOrder.status = ORDER_PARTIALLY_FILLED;

        // Update the order book to reflect the partial fill
        /// @dev This updates the volume at the price point in the order book
        (matchedOrder.isBuy ? pair.buyOrders : pair.sellOrders).update(matchedOrder.price, takerOrder.quantity);

        // Set the taker order quantity to 0 as it has been fully filled
        takerOrder.quantity = 0;
        takerOrder.availableQuantity = 0;

        // Emit an event for the filled taker order
        emit OrderFilled(takerOrder.id, pair.baseToken, pair.quoteToken, msg.sender);

        // Emit an event for the partially filled matched order
        emit OrderPartiallyFilled(matchedOrder.id, pair.baseToken, pair.quoteToken, matchedOrder.traderAddress);
    }

    /// @notice Matches a new order against existing orders in the order book
    /// @dev This function attempts to fill the new order by matching it against existing orders
    /// @param pair The storage reference to the Pair struct
    /// @param orderCount The current count of orders processed in this matching session
    /// @param newOrder The new order to be matched against existing orders
    /// @return uint256 The remaining quantity of the new order after matching
    /// @return uint256 The updated count of orders processed in this matching session
    function matchOrder(Pair storage pair, uint256 orderCount, OrderBookLib.Order memory newOrder)
        private
        returns (uint256, uint256)
    {
        // Determine the first matching order ID based on whether the new order is a buy or sell
        bytes32 matchingOrderId = newOrder.isBuy
            ? pair.sellOrders.getNextOrderIdAtPrice(pair.sellOrders.getLowestPrice())
            : pair.buyOrders.getNextOrderIdAtPrice(pair.buyOrders.getHighestPrice());

        // Continue matching until we run out of matching orders or hit the maximum number of orders to fill
        do {
            // Get the matching order from storage
            OrderBookLib.Order storage matchingOrder = pair.orders[matchingOrderId];

            // Check if the new order can fully fill the matching order
            if (newOrder.quantity >= matchingOrder.availableQuantity) {
                // Fully fill the matching order
                fillOrder(pair, matchingOrder, newOrder);
                // Check if there are more orders at the same price
                /// @dev We use the appropriate order book (sell for buy orders, buy for sell orders)
                matchingOrderId =
                    (newOrder.isBuy ? pair.sellOrders : pair.buyOrders).getNextOrderIdAtPrice(matchingOrder.price);
            } else {
                // Partially fill the matching order
                partiallyFillOrder(pair, matchingOrder, newOrder);
                // Return as the new order has been fully filled
                return (newOrder.quantity, orderCount);
            }

            // Check if the new order has been fully filled
            if (newOrder.quantity == 0) {
                emit OrderFilled(newOrder.id, pair.baseToken, pair.quoteToken, newOrder.traderAddress);
                return (newOrder.quantity, orderCount);
            }

            // Increment the order count to keep track of how many orders have been processed
            ++orderCount;
        } while (matchingOrderId != 0 && orderCount < MAX_NUMBER_ORDERS_FILLED);

        // Return the remaining quantity of the new order and the updated order count
        return (newOrder.quantity, orderCount);
    }

    /// @notice Creates a new order in the order book
    /// @dev This function handles both the creation of new orders and matching against existing orders
    /// @param pair The storage reference to the Pair struct
    /// @param isBuy Boolean indicating whether this is a buy order (true) or sell order (false)
    /// @param _price The price at which the order is placed
    /// @param _quantity The quantity of tokens to be traded
    /// @param timestamp The timestamp of the order creation
    function createOrder(Pair storage pair, bool isBuy, uint256 _price, uint256 _quantity, uint256 timestamp) private {
        // Validate input parameters
        if (_price == 0) revert PL__InvalidPrice(_price);
        if (_quantity == 0) revert PL__InvalidQuantity(_quantity);

        // Determine the current best price point to start matching
        uint256 currentPricePoint = isBuy ? pair.sellOrders.getLowestPrice() : pair.buyOrders.getHighestPrice();

        // Generate a unique order ID
        bytes32 _orderId = keccak256(abi.encodePacked(msg.sender, isBuy ? "buy" : "sell", _price, timestamp));

        // Check if an order with the same ID already exists
        if (orderExists(pair, _orderId)) revert PL__OrderIdAlreadyExists();

        // Create a new order struct
        OrderBookLib.Order memory newOrder = OrderBookLib.Order({
            id: _orderId,
            price: _price,
            quantity: _quantity,
            availableQuantity: _quantity,
            isBuy: isBuy,
            createdAt: timestamp,
            traderAddress: msg.sender,
            status: ORDER_CREATED
        });

        // Initialize order count for matching
        uint256 orderCount;

        // Attempt to match the new order against existing orders
        while (_quantity > 0 && orderCount < MAX_NUMBER_ORDERS_FILLED) {
            // If there are no more orders to match against, exit the loop
            if (currentPricePoint == 0) {
                break;
            }

            // Determine if the new order should be matched at the current price point
            bool shouldMatch = isBuy ? newOrder.price >= currentPricePoint : newOrder.price <= currentPricePoint;

            if (shouldMatch) {
                // Match the order and update remaining quantity
                (_quantity, orderCount) = matchOrder(pair, orderCount, newOrder);
                newOrder.quantity = _quantity;
                // Update the current price point for the next iteration
                currentPricePoint = isBuy ? pair.sellOrders.getLowestPrice() : pair.buyOrders.getHighestPrice();
            } else {
                // If the current price is not favorable, stop matching
                break;
            }
        }

        // If there's remaining quantity after matching, add the order to the book
        if (_quantity > 0) {
            addOrder(pair, newOrder);
        }
    }

    /// @notice Retrieves the balance of a trader for a specific trading pair
    /// @dev This function returns the current balance of base and quote tokens for a given trader
    /// @param pair The storage reference to the Pair struct containing trader balances
    /// @param _trader The address of the trader whose balance is being queried
    /// @return TraderBalance A struct containing the trader's base and quote token balances
    function getTraderBalances(Pair storage pair, address _trader) internal view returns (TraderBalance memory) {
        return pair.traderBalances[_trader];
    }

    /// @notice Retrieves all order IDs for a specific trader
    /// @dev This function returns an array of order IDs associated with the given trader's address
    /// @param pair The storage reference to the Pair struct
    /// @param _trader The address of the trader whose orders are being retrieved
    /// @return bytes32[] memory An array of order IDs belonging to the trader
    function getTraderOrders(Pair storage pair, address _trader) internal view returns (bytes32[] memory) {
        return pair.traderOrderRegistry[_trader].orderIds;
    }

    /// @notice Retrieves the details of a specific order
    /// @dev This function returns the full Order struct for a given order ID
    /// @param pair The storage reference to the Pair struct
    /// @param orderId The unique identifier of the order
    /// @return OrderBookLib.Order storage The order details
    /// @custom:throws PL__OrderIdDoesNotExist if the order ID does not exist
    function getOrderDetail(Pair storage pair, bytes32 orderId) internal view returns (OrderBookLib.Order storage) {
        if (!orderExists(pair, orderId)) revert PL__OrderIdDoesNotExist();
        return pair.orders[orderId];
    }

    /// @notice Gets the lowest buy price in the order book
    /// @dev This function returns the lowest price at which there is a buy order
    /// @param pair The storage reference to the Pair struct
    /// @return uint256 The lowest buy price, or 0 if there are no buy orders
    function getLowestBuyPrice(Pair storage pair) internal view returns (uint256) {
        return pair.buyOrders.getLowestPrice();
    }

    /// @notice Gets the lowest sell price in the order book
    /// @dev This function returns the lowest price at which there is a sell order
    /// @param pair The storage reference to the Pair struct
    /// @return uint256 The lowest sell price, or 0 if there are no sell orders
    function getLowestSellPrice(Pair storage pair) internal view returns (uint256) {
        return pair.sellOrders.getLowestPrice();
    }

    /// @notice Gets the highest buy price in the order book
    /// @dev This function returns the highest price at which there is a buy order
    /// @param pair The storage reference to the Pair struct
    /// @return uint256 The highest buy price, or 0 if there are no buy orders
    function getHighestBuyPrice(Pair storage pair) internal view returns (uint256) {
        return pair.buyOrders.getHighestPrice();
    }

    /// @notice Retrieves the ID of the next buy order at a specific price
    /// @dev This function is used to traverse the order book for buy orders
    /// @param pair The storage reference to the Pair struct
    /// @param price The price point to check for the next buy order
    /// @return bytes32 The ID of the next buy order at the specified price, or 0 if none exists
    function getNextBuyOrderId(Pair storage pair, uint256 price) internal view returns (bytes32) {
        return pair.buyOrders.getNextOrderIdAtPrice(price);
    }

    /// @notice Retrieves the top 3 buy prices in the order book
    /// @dev This function returns an array of the 3 highest buy prices
    /// @param pair The storage reference to the Pair struct
    /// @return uint256[3] memory An array containing the top 3 buy prices, sorted in descending order
    function getTop3BuyPrices(Pair storage pair) internal view returns (uint256[3] memory) {
        return pair.buyOrders.get3Prices(true);
    }

    /// @notice Retrieves the top 3 sell prices in the order book
    /// @dev This function returns an array of the 3 lowest sell prices
    /// @param pair The storage reference to the Pair struct
    /// @return uint256[3] memory An array containing the top 3 sell prices, sorted in ascending order
    function getTop3SellPrices(Pair storage pair) internal view returns (uint256[3] memory) {
        return pair.sellOrders.get3Prices(false);
    }

    /// @notice Retrieves the PricePoint data for a specific price in either the buy or sell order book
    /// @dev This function returns detailed information about orders at a specific price point
    /// @param pair The storage reference to the Pair struct
    /// @param price The price point to query
    /// @param isBuy A boolean indicating whether to query the buy (true) or sell (false) order book
    /// @return OrderBookLib.PricePoint storage The PricePoint data for the specified price
    function getPrice(Pair storage pair, uint256 price, bool isBuy)
        internal
        view
        returns (OrderBookLib.PricePoint storage)
    {
        return (isBuy ? pair.buyOrders : pair.sellOrders).getPricePointData(price);
    }

    /// @notice Checks if an order with the given ID exists in the order book
    /// @dev This function is used internally to verify the existence of an order
    /// @param pair The storage reference to the Pair struct
    /// @param _orderId The ID of the order to check
    /// @return bool True if the order exists, false otherwise
    function orderExists(Pair storage pair, bytes32 _orderId) private view returns (bool) {
        // An order exists if its ID in the orders mapping is not the zero bytes32
        return pair.orders[_orderId].id != bytes32(0);
    }
}
