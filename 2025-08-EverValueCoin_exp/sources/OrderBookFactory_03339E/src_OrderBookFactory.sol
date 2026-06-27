// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./OrderBookLib.sol";
import "./RedBlackTreeLib.sol";
import {PairLib} from "./PairLib.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title OrderBookFactory - Main Contract for Order Book Management
 * @author Diego Leal / Angel García / Artech Software
 * @notice This contract manages the creation and administration of order books for trading pairs
 * @dev This contract inherits from ReentrancyGuard, Pausable, and Ownable for added security and control
 */
contract OrderBookFactory is ReentrancyGuard, Pausable, Ownable2Step {
    /// @dev Utilizes PairLib for managing trading pairs
    using PairLib for PairLib.Pair;
    /// @dev Utilizes OrderBookLib for managing individual orders
    using OrderBookLib for OrderBookLib.Order;
    /// @dev Utilizes OrderBookLib for managing price points
    using OrderBookLib for OrderBookLib.PricePoint;

    /**
     * @dev Maximum fee in basis points (2%)
     * This constant limits the maximum fee that can be set for a trading pair
     */
    uint256 private constant MAX_FEE = 200;

    /**
     * @dev Array to store all pair IDs
     * This allows for easy iteration over all trading pairs
     */
    bytes32[] public pairIds;

    /**
     * @dev Mapping from pair ID to Pair struct
     * Stores all information related to a specific trading pair
     */
    mapping(bytes32 => PairLib.Pair) pairs;

    /// @notice Thrown when an invalid token address (zero address) is provided
    error OBF__InvalidTokenAddress();

    /// @notice Thrown when an invalid fee address (zero address) is provided
    error OBF__InvalidFeeAddress();

    /// @notice Thrown when attempting to create a pair with the same token for both base and quote
    error OBF__TokensMustBeDifferent();

    /// @notice Thrown when trying to perform an operation on a non-existent pair
    error OBF__PairDoesNotExist();

    /// @notice Thrown when attempting to place an order with zero quantity
    error OBF__InvalidQuantityValueZero();

    /// @notice Thrown when trying to interact with a pair that is not enabled
    error OBF__PairNotEnabled();

    /// @notice Thrown when attempting to create a pair that already exists
    error OBF__PairAlreadyExists();

    /// @notice Thrown when the proposed fee exceeds the maximum allowed fee
    /// @param fee The proposed fee that caused the error
    /// @param maxFee The maximum allowed fee
    error OBF__FeeExceedsMaximum(uint256 fee, uint256 maxFee);

    /// @notice Emitted when a new order book is created
    /// @param id The unique identifier of the new order book
    /// @param baseToken The address of the base token in the trading pair
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param owner The address of the owner who created the order book
    event OrderBookCreated(bytes32 indexed id, address indexed baseToken, address indexed quoteToken, address owner);

    /// @notice Emitted when the status of an order book is changed
    /// @param id The unique identifier of the affected order book
    /// @param enabled The new status of the order book (true if enabled, false if disabled)
    event PairStatusChanged(bytes32 indexed id, bool enabled);

    /// @notice Emitted when the fee for an order book is updated
    /// @param id The unique identifier of the affected order book
    /// @param newFee The new fee value set for the order book
    event PairFeeChanged(bytes32 indexed id, uint256 newFee);

    /// @notice Emitted when the fee recipient address for an order book is changed
    /// @param id The unique identifier of the affected order book
    /// @param newFeeAddress The new address that will receive the fees for this order book
    event PairFeeAddressChanged(bytes32 indexed id, address newFeeAddress);

    /// @notice Emitted when the pause status of the entire contract is changed
    /// @param isPaused The new pause status of the contract (true if paused, false if unpaused)
    event ContractPauseStatusChanged(bool isPaused);

    /// @notice Modifier to restrict operations to enabled pairs only
    /// @dev This modifier checks if the specified pair is enabled before executing the function
    /// @param _pairId The unique identifier of the pair to check
    modifier onlyEnabledPair(bytes32 _pairId) {
        if (!pairs[_pairId].enabled) revert OBF__PairNotEnabled();
        _;
    }

    /// @notice Contract constructor
    /// @dev Initializes the contract and sets the deployer as the owner
    constructor() Ownable(msg.sender) {}

    /// @notice Adds a new order book to the mapping
    /// @dev Creates a new trading pair and its associated order book with specified parameters
    /// @param quoteToken The address of the quote token in the trading pair
    /// @param baseToken The address of the base token in the trading pair
    /// @param initialFee The initial fee percentage (in basis points) for transactions in this order book
    /// @param feeAddress The address that will receive the collected fees
    /// @custom:security This function is only callable by the contract owner and when the contract is not paused
    function addPair(address quoteToken, address baseToken, uint256 initialFee, address feeAddress)
        external
        onlyOwner
        whenNotPaused
    {
        // Validate input parameters
        if (quoteToken == address(0) || baseToken == address(0)) revert OBF__InvalidTokenAddress();
        if (feeAddress == address(0)) revert OBF__InvalidFeeAddress();
        if (quoteToken == baseToken) revert OBF__TokensMustBeDifferent();
        if (initialFee > MAX_FEE) revert OBF__FeeExceedsMaximum(initialFee, MAX_FEE);

        // Create a unique identifier for the pair
        // This ensures that (TokenA, TokenB) and (TokenB, TokenA) create the same pair
        bytes32 identifier = uint160(quoteToken) > uint160(baseToken)
            ? keccak256(abi.encodePacked(quoteToken, baseToken))
            : keccak256(abi.encodePacked(baseToken, quoteToken));

        // Check if the pair already exists
        if (pairExists(identifier)) revert OBF__PairAlreadyExists();

        // Add the new pair identifier to the list of all pairs
        pairIds.push(identifier);

        // Create and initialize the new pair
        PairLib.Pair storage newPair = pairs[identifier];
        newPair.baseToken = baseToken;
        newPair.quoteToken = quoteToken;
        newPair.lastTradePrice = 0;
        newPair.enabled = true;
        newPair.fee = initialFee;
        newPair.feeAddress = feeAddress;

        // Emit an event to log the creation of the new order book
        emit OrderBookCreated(identifier, baseToken, quoteToken, msg.sender);
    }

    /// @notice Retrieves all pair IDs
    /// @dev This function allows external contracts or users to get a list of all trading pair identifiers
    /// @return An array of bytes32 containing all pair IDs
    function getPairIds() external view returns (bytes32[] memory) {
        return pairIds;
    }

    /// @notice Retrieves detailed information about a specific trading pair
    /// @dev This function provides comprehensive data about a pair, including its current status and fee information
    /// @param _pairId The unique identifier of the pair to query
    /// @return baseToken The address of the base token in the pair
    /// @return quoteToken The address of the quote token in the pair
    /// @return status Whether the pair is currently enabled or disabled
    /// @return lastTradePrice The price of the last executed trade for this pair
    /// @return fee The current fee percentage for trades in this pair
    /// @return feeAddress The address currently set to receive fees from this pair's trades
    function getPairById(bytes32 _pairId)
        external
        view
        returns (
            address baseToken,
            address quoteToken,
            bool status,
            uint256 lastTradePrice,
            uint256 fee,
            address feeAddress
        )
    {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        return (
            pairs[_pairId].baseToken,
            pairs[_pairId].quoteToken,
            pairs[_pairId].enabled,
            pairs[_pairId].lastTradePrice,
            pairs[_pairId].fee,
            pairs[_pairId].feeAddress
        );
    }

    /// @notice Changes the enabled status of a trading pair
    /// @dev This function allows the owner to enable or disable trading for a specific pair
    /// @param _pairId The unique identifier of the pair to modify
    /// @param _enabled The new status to set (true to enable, false to disable)
    function setPairStatus(bytes32 _pairId, bool _enabled) external onlyOwner {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        pairs[_pairId].enabled = _enabled;

        emit PairStatusChanged(_pairId, _enabled);
    }

    /// @notice Updates the fee for a specific trading pair
    /// @dev This function allows the owner to change the fee percentage for a pair
    /// @param _pairId The unique identifier of the pair to modify
    /// @param newFee The new fee percentage to set (in basis points)
    function setPairFee(bytes32 _pairId, uint256 newFee) external onlyOwner {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        if (newFee > MAX_FEE) revert OBF__FeeExceedsMaximum(newFee, MAX_FEE);
        pairs[_pairId].changePairFee(newFee);

        emit PairFeeChanged(_pairId, newFee);
    }

    /// @notice Sets a new fee recipient address for a specific order book
    /// @dev This function allows the owner to change the address that receives fees for a particular trading pair
    /// @param _pairId The unique identifier of the pair to modify
    /// @param newFeeAddress The new address that will receive the fees
    function setPairFeeAddress(bytes32 _pairId, address newFeeAddress) external onlyOwner {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        if (newFeeAddress == address(0)) revert OBF__InvalidFeeAddress();
        pairs[_pairId].feeAddress = newFeeAddress;

        emit PairFeeAddressChanged(_pairId, newFeeAddress);
    }
    /// @notice Adds a new order to the order book
    /// @dev This function allows users to place new buy or sell orders
    /// @param _pairId The unique identifier of the trading pair
    /// @param _quantity The amount of tokens to buy or sell
    /// @param _price The price at which to place the order
    /// @param _isBuy A boolean indicating whether this is a buy (true) or sell (false) order
    /// @param _timestamp The timestamp of when the order was created

    function addNewOrder(bytes32 _pairId, uint256 _quantity, uint256 _price, bool _isBuy, uint256 _timestamp)
        external
        onlyEnabledPair(_pairId)
        nonReentrant
        whenNotPaused
    {
        if (_isBuy) {
            pairs[_pairId].addBuyOrder(_price, _quantity, _timestamp);
        } else {
            pairs[_pairId].addSellOrder(_price, _quantity, _timestamp);
        }
    }

    /// @notice Cancels an existing order
    /// @dev This function allows users to cancel their own orders
    /// @param _pairId The unique identifier of the trading pair
    /// @param _orderId The unique identifier of the order to be cancelled
    function cancelOrder(bytes32 _pairId, bytes32 _orderId) external nonReentrant {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        pairs[_pairId].cancelOrder(_orderId);
    }

    /// @notice Pauses all operations in the contract
    /// @dev Only the owner can call this function. It uses OpenZeppelin's Pausable functionality.
    function pause() external onlyOwner {
        _pause();
        emit ContractPauseStatusChanged(true);
    }

    /// @notice Resumes all operations in the contract
    /// @dev Only the owner can call this function. It uses OpenZeppelin's Pausable functionality.
    function unpause() external onlyOwner {
        _unpause();
        emit ContractPauseStatusChanged(false);
    }

    /// @notice Retrieves the fee percentage for a specific trading pair
    /// @dev This function returns the current fee in basis points
    /// @param _pairId The unique identifier of the trading pair
    /// @return The fee percentage in basis points (e.g., 100 means 1%)
    function getPairFee(bytes32 _pairId) external view returns (uint256) {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        return pairs[_pairId].fee;
    }

    /// @notice Retrieves all order IDs for a specific trader in a given pair
    /// @dev This function allows querying all orders placed by a trader in a specific order book
    /// @param _pairId The unique identifier of the trading pair
    /// @param _trader The address of the trader whose orders are being queried
    /// @return An array of bytes32 representing the order IDs
    function getTraderOrdersForPair(bytes32 _pairId, address _trader) external view returns (bytes32[] memory) {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();

        return pairs[_pairId].getTraderOrders(_trader);
    }

    /// @notice Retrieves detailed information about a specific order
    /// @dev This function returns the full Order struct for a given order ID
    /// @param _pairId The unique identifier of the trading pair
    /// @param _orderId The unique identifier of the order
    /// @return An OrderBookLib.Order struct containing all details of the order
    function getOrderDetailForPair(bytes32 _pairId, bytes32 _orderId)
        external
        view
        returns (OrderBookLib.Order memory)
    {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();

        return pairs[_pairId].getOrderDetail(_orderId);
    }

    /// @notice Retrieves the top 3 buy prices for a specific pair
    /// @dev This function returns the highest 3 prices in the buy order book
    /// @param pairId The unique identifier of the trading pair
    /// @return An array of 3 uint256 values representing the top buy prices
    function getTop3BuyPricesForPair(bytes32 pairId) external view returns (uint256[3] memory) {
        return pairs[pairId].getTop3BuyPrices();
    }

    /// @notice Retrieves the top 3 sell prices for a specific pair
    /// @dev This function returns the lowest 3 prices in the sell order book
    /// @param pairId The unique identifier of the trading pair
    /// @return An array of 3 uint256 values representing the top sell prices
    function getTop3SellPricesForPair(bytes32 pairId) external view returns (uint256[3] memory) {
        return pairs[pairId].getTop3SellPrices();
    }

    /// @notice Retrieves data for a specific price point in the order book
    /// @dev This function returns the number of orders and total value at a given price
    /// @param _pairId The unique identifier of the trading pair
    /// @param price The price point to query
    /// @param isBuy Whether to query the buy (true) or sell (false) side of the order book
    /// @return orderCount The number of orders at the specified price
    /// @return orderValue The total value of all orders at the specified price
    function getPricePointDataForPair(bytes32 _pairId, uint256 price, bool isBuy)
        external
        view
        returns (uint256 orderCount, uint256 orderValue)
    {
        OrderBookLib.PricePoint storage p = pairs[_pairId].getPrice(price, isBuy);
        return (p.orderCount, p.orderValue);
    }

    /// @notice Retrieves the balance of a trader for a specific trading pair
    /// @dev This function allows querying the current balance of a trader in both base and quote tokens
    /// @param _pairId The unique identifier of the trading pair
    /// @param _trader The address of the trader whose balance is being queried
    /// @return PairLib.TraderBalance A struct containing the trader's balance information
    /// @custom:security This function is view-only and does not modify state
    function checkBalanceTrader(bytes32 _pairId, address _trader)
        external
        view
        returns (PairLib.TraderBalance memory)
    {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        return pairs[_pairId].getTraderBalances(_trader);
    }

    /// @notice Allows a trader to withdraw their balance from a specific trading pair
    /// @dev This function enables traders to withdraw their available balance (both base and quote tokens)
    /// @param _pairId The unique identifier of the trading pair from which to withdraw
    /// @param baseTokenWithdrawal if true withdraws base token's balance, if false withdraws quote token's balance
    /// @custom:security This function is external and can be called by any address
    /// @custom:security Implements a nonReentrant guard to prevent reentrancy attacks
    function withdrawBalanceTrader(bytes32 _pairId, bool baseTokenWithdrawal) external nonReentrant {
        if (!pairExists(_pairId)) revert OBF__PairDoesNotExist();
        pairs[_pairId].withdrawBalance(msg.sender, baseTokenWithdrawal);
    }

    /// @notice Checks if a trading pair exists
    /// @dev A pair is considered to exist if its baseToken is not the zero address
    /// @param _pairId The unique identifier of the trading pair to check
    /// @return bool True if the pair exists, false otherwise
    function pairExists(bytes32 _pairId) private view returns (bool) {
        return pairs[_pairId].baseToken != address(0x0);
    }
}
