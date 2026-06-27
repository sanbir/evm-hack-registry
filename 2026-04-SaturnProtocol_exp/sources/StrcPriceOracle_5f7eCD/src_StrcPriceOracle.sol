// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IStrcPriceOracle} from "./interfaces/IStrcPriceOracle.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title StrcPriceOracle
 * @author Saturn
 * @notice Implementation of the IStrcPriceOracle interface.
 * @dev Provides validated STRC price data by wrapping a Chainlink-compatible oracle
 * with staleness checks and price bounds validation.
 */
contract StrcPriceOracle is AccessControl, IStrcPriceOracle {
    /// @notice Maximum allowed staleness setting (36 hours)
    uint256 public constant MAX_STALENESS = 36 hours;

    /// @notice The current maximum price staleness setting.
    uint256 public maxPriceStaleness;

    /// @notice The minimum acceptable price from the oracle.
    uint256 public minPrice;

    /// @notice The maximum acceptable price from the oracle.
    uint256 public maxPrice;

    /// @dev The price oracle contract
    IPriceOracle private oracle;

    constructor(address defaultAdmin, address oracleAddress) {
        require(defaultAdmin != address(0) && oracleAddress != address(0), InvalidZeroAddress());

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        oracle = IPriceOracle(oracleAddress);
        maxPriceStaleness = 26 hours; // Oracle heartbeat is 24 hrs on Ethereum
        minPrice = 20e8; // $20 with 8 decimals
        maxPrice = 150e8; // $150 with 8 decimals
    }

    /// @inheritdoc IStrcPriceOracle
    function updateOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), InvalidZeroAddress());
        address oldOracle = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    /// @inheritdoc IStrcPriceOracle
    function setMaxPriceStaleness(uint256 newStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newStaleness <= MAX_STALENESS, InvalidStaleness());
        maxPriceStaleness = newStaleness;
        emit MaxPriceStalenessUpdated(newStaleness);
    }

    /// @inheritdoc IStrcPriceOracle
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMinPrice > 0 && newMinPrice < newMaxPrice, InvalidPriceBounds());
        minPrice = newMinPrice;
        maxPrice = newMaxPrice;
        emit PriceBoundsUpdated(newMinPrice, newMaxPrice);
    }

    /// @inheritdoc IStrcPriceOracle
    function getOracle() external view returns (address) {
        return address(oracle);
    }

    /// @inheritdoc IStrcPriceOracle
    function getPrice() external view returns (uint256 price, uint8 oracleDecimals) {
        require(address(oracle) != address(0), InvalidZeroAddress());

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();

        // Staleness check
        require(block.timestamp - updatedAt <= maxPriceStaleness, InvalidOraclePrice());
        require(answer > 0, InvalidOraclePrice());

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);

        // Bounds check
        require(price >= minPrice && price <= maxPrice, InvalidOraclePrice());

        oracleDecimals = oracle.decimals();
    }
}
