// SPDX-License-Identifier: BSL-1.1

pragma solidity ^0.8.26;

import "../lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../lib/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "../lib/v3-periphery/contracts/libraries/TransferHelper.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

abstract contract AbstractYodlRouter {
    string public version;
    address public yodlFeeTreasury;
    uint256 public yodlFeeBps;
    IWETH9 public wrappedNativeToken;
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MAX_EXTRA_FEE_BPS = 5_000; // 50%

    /// @notice Emitted when a payment goes through
    /// @param sender The address who has made the payment
    /// @param receiver The address who has received the payment
    /// @param token The address of the token that was used for the payment. Either an ERC20 token or the native token
    /// address.
    /// @param amount The amount paid by the sender in terms of the token
    /// @param fees The fees taken by the Yodl router from the amount paid
    /// @param memo The message attached to the payment
    event Yodl(
        address indexed sender, address indexed receiver, address token, uint256 amount, uint256 fees, bytes32 memo
    );

    /// @notice Emitted when a native token transfer occurs
    /// @param sender The address who has made the payment
    /// @param receiver The address who has received the payment
    /// @param amount The amount paid by the sender in terms of the native token
    event YodlNativeTokenTransfer(address indexed sender, address indexed receiver, uint256 indexed amount);

    /// @notice Emitted when a conversion has occurred from one currency to another using a Chainlink price feed
    /// @param priceFeed0 The address of the price feed used for conversion
    /// @param priceFeed1 The address of the price feed used for conversion
    /// @param exchangeRate0 The rate used from the price feed at the time of conversion
    /// @param exchangeRate1 The rate used from the price feed at the time of conversion
    event Convert(address indexed priceFeed0, address indexed priceFeed1, int256 exchangeRate0, int256 exchangeRate1);

    /**
     * @notice Struct to hold the YApp address and the YD ID
     * @param yApp The address of the YApp
     * @param yd The ID of the YD
     * @param payload The payload to be sent to the YApp
     */
    struct YApp {
        address yApp;
        uint256 sessionId;
        bytes[] payload;
    }

    /// @notice Enables the contract to receive Ether
    /// @dev We need a receive method for when we withdraw WETH to the router. It does not need to do anything.
    receive() external payable {}

    /**
     * @notice Calculates exchange rates from a given price feed
     * @dev At most we can have 2 price feeds.
     *
     * We will use a zero address to determine if we need to inverse a singular price feeds.
     *
     * For multiple price feeds, we will always pass them in such that we multiply by the first and divide by the second.
     * This works because all of our price feeds have USD as the quote currency.
     *
     * a) CHF_USD/_______    =>  85 CHF invoiced, 100 USD sent
     * b) _______/CHF_USD    => 100 USD invoiced,  85 CHF sent
     * c) ETH_USD/CHF_USD    => ETH invoiced,         CHF sent
     *
     * The second pricefeed is inversed. So in b) and c) `CHF_USD` turns into `USD_CHF`.
     *
     * @param priceFeeds Array of Chainlink price feeds
     * @param amount Amount to be converted by the price feed exchange rates
     * @return converted The amount after conversion
     * @return priceFeedsUsed The price feeds in the order they were used
     * @return prices The exchange rates from the price feeds
     */
    function exchangeRate(address[2] calldata priceFeeds, uint256 amount)
        public
        view
        returns (uint256 converted, address[2] memory priceFeedsUsed, int256[2] memory prices)
    {
        require(priceFeeds[0] != address(0) || priceFeeds[1] != address(0), "invalid pricefeeds");

        bool shouldInverse;

        AggregatorV3Interface priceFeedOne;
        AggregatorV3Interface priceFeedTwo; // might not exist

        if (priceFeeds[0] == address(0)) {
            // Inverse the price feed. invoiceAmount: USD, settlementAmount: CHF
            shouldInverse = true;
            priceFeedOne = AggregatorV3Interface(priceFeeds[1]);
        } else {
            // No need to inverse. invoiceAmount: CHF, settlementAmount: USD
            priceFeedOne = AggregatorV3Interface(priceFeeds[0]);
            if (priceFeeds[1] != address(0)) {
                // Multiply by the first, divide by the second
                // Will always be A -> USD -> B
                priceFeedTwo = AggregatorV3Interface(priceFeeds[1]);
            }
        }

        // Calculate the converted value using price feeds
        uint256 decimals = uint256(10 ** uint256(priceFeedOne.decimals()));
        (, int256 price,,,) = priceFeedOne.latestRoundData();
        prices[0] = price;
        if (shouldInverse) {
            converted = (amount * decimals) / uint256(price);
        } else {
            converted = (amount * uint256(price)) / decimals;
        }

        // We will always divide by the second price feed
        if (address(priceFeedTwo) != address(0)) {
            decimals = uint256(10 ** uint256(priceFeedTwo.decimals()));
            (, price,,,) = priceFeedTwo.latestRoundData();
            prices[1] = price;
            converted = (converted * decimals) / uint256(price);
        }

        return (converted, [address(priceFeedOne), address(priceFeedTwo)], prices);
    }

    /// @notice Helper function to calculate fees
    /// @dev A basis point is 0.01% -> 1/10000 is one basis point
    /// So multiplying by the amount of basis points then dividing by 10000
    /// will give us the fee as a portion of the original amount, expressed in terms of basis points.
    ///
    /// Overflows are allowed to occur at ridiculously large amounts.
    /// @param amount The amount to calculate the fee for
    /// @param feeBps The size of the fee in terms of basis points
    /// @return The fee
    function calculateFee(uint256 amount, uint256 feeBps) public pure returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    /// @notice Transfers all fees or slippage collected by the router to the treasury address
    /// @param token The address of the token we want to transfer from the router
    function sweep(address token) external {
        if (token == NATIVE_TOKEN) {
            // transfer native token out of contract
            (bool success,) = yodlFeeTreasury.call{value: address(this).balance}("");
            require(success, "transfer failed in sweep");
        } else {
            // transfer ERC20 contract
            TransferHelper.safeTransfer(token, yodlFeeTreasury, IERC20(token).balanceOf(address(this)));
        }
    }

    /// @notice Calculates and transfers fee directly from an address to another
    /// @dev This can be used for directly transferring the Yodl fee from the sender to the treasury, or transferring
    /// the extra fee to the extra fee receiver.
    /// @param amount Amount from which to calculate the fee
    /// @param feeBps The size of the fee in basis points
    /// @param token The token which is being used to pay the fee. Can be an ERC20 token or the native token
    /// @param from The address from which we are transferring the fee
    /// @param to The address to which the fee will be sent
    /// @return The fee sent
    function transferFee(uint256 amount, uint256 feeBps, address token, address from, address to)
        public
        returns (uint256)
    {
        uint256 fee = calculateFee(amount, feeBps);
        if (fee > 0) {
            if (token != NATIVE_TOKEN) {
                // ERC20 token
                if (from == address(this)) {
                    TransferHelper.safeTransfer(token, to, fee);
                } else {
                    // safeTransferFrom requires approval
                    TransferHelper.safeTransferFrom(token, from, to, fee);
                }
            } else {
                require(from == address(this), "can only transfer eth from the router address");

                // Native ether
                (bool success,) = to.call{value: fee}("");
                require(success, "transfer failed in transferFee");
            }
            return fee;
        } else {
            return 0;
        }
    }
}
