// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "../../interfaces/IMToken.sol";
import "../../interfaces/IPriceOracle.sol";
import "../../libraries/ErrorCodes.sol";
import "./interfaces/IRWAOracle.sol";

contract AggregatedPriceOracle is IPriceOracle, AccessControl {
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     *  @notice List of supported oracle providers
     */
    enum OracleProviderType {
        Api3,
        RWADynamicOracle,
        // For some tokens we can use multiplication of two oracles
        // For example, for mETH we use mETH/ETH and ETH/USD oracles
        Api3Aggregated
    }

    /**
     *  @notice Structure to store oracle related data for the token
     */
    struct TokenConfig {
        /// @dev The price feed contract address.
        address proxyPriceFeedAddress;
        /// @dev Second price feed (for Api3Aggregated oracle provider)
        address secondaryProxyPriceFeedAddress;
        /// @dev Maximum age of the on-chain price in seconds.
        uint32 maxValidPriceAge;
        // @dev Original token decimals
        uint32 underlyingTokenDecimals;
        // @dev For some tokens we use token-specific oracle providers
        OracleProviderType oracleProviderType;
    }

    event NewTokenConfigSet(
        address token,
        address proxyPriceFeedAddress,
        address secondaryProxyPriceFeedAddress,
        uint32 maxValidPriceAge,
        uint32 underlyingTokenDecimals,
        OracleProviderType oracleProviderType
    );

    /// @dev Mapping to store oracle related configuration for tokens
    mapping(address => TokenConfig) public feedProxies;

    /**
     * @notice Construct a ChainlinkPriceOracle contract.
     * @param admin The address of the Admin
     */
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function pow10(uint8 power) private pure returns (uint256) {
        if (power == 22) return 1e22;
        else if (power == 20) return 1e20;
        else if (power == 10) return 1e10;
        else if (power == 1) return 1e1;
        else if (power == 2) return 1e2;
        else if (power == 3) return 1e3;
        else if (power == 4) return 1e4;
        else if (power == 5) return 1e5;
        else if (power == 6) return 1e6;
        else if (power == 7) return 1e7;
        else if (power == 8) return 1e8;
        else if (power == 9) return 1e9;
        else if (power == 11) return 1e11;
        else if (power == 12) return 1e12;
        else if (power == 13) return 1e13;
        else if (power == 14) return 1e14;
        else if (power == 15) return 1e15;
        else if (power == 16) return 1e16;
        else if (power == 17) return 1e17;
        else if (power == 18) return 1e18;
        else if (power == 19) return 1e19;
        else if (power == 21) return 1e21;
        else if (power == 23) return 1e23;
        else if (power == 24) return 1e24;
        else if (power == 25) return 1e25;
        else if (power == 26) return 1e26;
        else if (power == 27) return 1e27;
        else if (power == 28) return 1e28;
        else if (power == 29) return 1e29;
        else if (power == 30) return 1e30;
        else if (power == 31) return 1e31;
        else if (power == 32) return 1e32;
        else if (power == 33) return 1e33;
        else if (power == 34) return 1e34;
        else if (power == 35) return 1e35;
        else return 1e36;
    }

    /**
     * @notice Convert price received from oracle to be scaled by (36 - tokenDecimals)
     * @param config token config
     * @param reportedPrice raw oracle price
     * @return price scaled by (36 - tokenDecimals)
     */
    function convertReportedPrice(TokenConfig memory config, int224 reportedPrice) internal pure returns (uint256) {
        require(reportedPrice > 0, ErrorCodes.REPORTED_PRICE_SHOULD_BE_GREATER_THAN_ZERO);

        uint256 unsignedPrice = uint256(uint224(reportedPrice));
        if (config.underlyingTokenDecimals == 18) return unsignedPrice;

        uint8 multiplier = 18 - uint8(config.underlyingTokenDecimals);

        return unsignedPrice * pow10(multiplier);
    }

    /// @inheritdoc IPriceOracle
    function getUnderlyingPrice(IMToken mToken) external view returns (uint256) {
        require(address(mToken) != address(0), ErrorCodes.MTOKEN_ADDRESS_CANNOT_BE_ZERO);
        return getAssetPrice(address(mToken.underlying()));
    }

    /// @inheritdoc IPriceOracle
    function getAssetPrice(address underlyingAsset) public view returns (uint256) {
        require(underlyingAsset != address(0), ErrorCodes.TOKEN_ADDRESS_CANNOT_BE_ZERO);

        TokenConfig memory config = feedProxies[underlyingAsset];
        require(config.proxyPriceFeedAddress != address(0), ErrorCodes.PRICE_FEED_ADDRESS_NOT_FOUND);

        (int224 currentPrice, uint32 publishTime) = getRawPrice(config);

        require(block.timestamp - publishTime <= config.maxValidPriceAge, ErrorCodes.ORACLE_PRICE_EXPIRED);

        return convertReportedPrice(config, currentPrice);
    }

    /**
     * @notice Return price and timestamp with regards to the oracle provider type
     * @param config Token config
     */
    function getRawPrice(TokenConfig memory config) internal view returns (int224, uint32) {
        if (config.oracleProviderType == OracleProviderType.Api3) {
            (int224 price, uint32 timestamp) = IProxy(config.proxyPriceFeedAddress).read();
            return (price, timestamp);
        } else if (config.oracleProviderType == OracleProviderType.RWADynamicOracle) {
            (uint256 price, uint256 timestamp) = IRWAOracle(config.proxyPriceFeedAddress).getPriceData();
            return ((price.toInt256()).toInt224(), timestamp.toUint32());
        } else if (config.oracleProviderType == OracleProviderType.Api3Aggregated) {
            (int224 price1, uint32 timestamp1) = IProxy(config.proxyPriceFeedAddress).read();
            (int224 price2, uint32 timestamp2) = IProxy(config.secondaryProxyPriceFeedAddress).read();
            int224 price = (price1 * price2) / 1e18;
            uint32 timestamp = timestamp1 > timestamp2 ? timestamp2 : timestamp1;
            return (price, timestamp);
        } else {
            revert("Incorrect oracle provider type");
        }
    }

    /**
     * @notice Set the price config for a underlying asset
     * @param underlyingAsset The address of underlying asset to set the price oracle for
     * @param proxyPriceFeedAddress The address of price feed contract
     * @param maxValidPriceAge Maximum age of the on-chain price in seconds.
     * @param underlyingTokenDecimals Original token decimals
     * @param oracleProviderType The identification of the oracle provider
     * @dev RESTRICTION: Admin only
     */
    function setTokenConfig(
        address underlyingAsset,
        address proxyPriceFeedAddress,
        address secondaryProxyPriceFeedAddress,
        uint32 maxValidPriceAge,
        uint32 underlyingTokenDecimals,
        OracleProviderType oracleProviderType
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(underlyingAsset != address(0), ErrorCodes.TOKEN_ADDRESS_CANNOT_BE_ZERO);
        require(proxyPriceFeedAddress != address(0), ErrorCodes.OR_INCORRECT_PRICE_FEED_ADDRESS);
        require(
            (secondaryProxyPriceFeedAddress != address(0) && oracleProviderType == OracleProviderType.Api3Aggregated) ||
                (secondaryProxyPriceFeedAddress == address(0) &&
                    oracleProviderType != OracleProviderType.Api3Aggregated),
            ErrorCodes.OR_INCORRECT_SECONDARY_PRICE_FEED_ADDRESS
        );
        require(maxValidPriceAge > 0, ErrorCodes.OR_PRICE_AGE_CAN_NOT_BE_ZERO);
        require(underlyingTokenDecimals > 0, ErrorCodes.OR_UNDERLYING_TOKENS_DECIMALS_SHOULD_BE_GREATER_THAN_ZERO);
        require(underlyingTokenDecimals <= 18, ErrorCodes.OR_UNDERLYING_TOKENS_DECIMALS_TOO_BIG);

        feedProxies[underlyingAsset] = TokenConfig(
            proxyPriceFeedAddress,
            secondaryProxyPriceFeedAddress,
            maxValidPriceAge,
            underlyingTokenDecimals,
            oracleProviderType
        );

        emit NewTokenConfigSet(
            underlyingAsset,
            proxyPriceFeedAddress,
            secondaryProxyPriceFeedAddress,
            maxValidPriceAge,
            underlyingTokenDecimals,
            oracleProviderType
        );
    }
}
