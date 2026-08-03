// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BasePriceOracle} from "./BasePriceOracle.sol";
import {IRedstoneOracle} from "./defaultOracles/IRedSToneOracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IBorrowing} from "../interface/IBorrowing.sol";
import "hardhat/console.sol";

/**
 * @title MasterPriceOracle
 * @notice Use a combination of price oracles.
 * @dev Implements `PriceOracle`.
 */
contract MasterPriceOracle is Initializable, BasePriceOracle {
    /**
     * @dev Maps underlying token addresses to `PriceOracle` address
     */
    mapping(address underlying => address oracleAddress) public oracles;
    mapping(IBorrowing.AssetName => address assetAddress) public assetAddress; // Mapping to address of the collateral

    /**
     * @dev  Initialize state variables.
     * @param underlyings The underlying asset addresses to link to `_oracles`.
     * @param _oracles The `PriceOracle` addresses to be assigned to `underlyings`.
     */
    constructor(
        address[] memory underlyings,
        address[] memory _oracles
    ) {

        // Get the total number of collateral addresses
        uint16 noOfUnderlyings = uint16(underlyings.length);

        // Check the number of pricefeed addresses and collateral addresses are same
        if (noOfUnderlyings != _oracles.length) revert Oracle_CollateralAddressesAndPriceFeedIdsMustBeSameLength();

        // Loop through the number of collateral address
        for (uint256 i = 0; i < noOfUnderlyings; i++) {
            // Assign the value(pricefeed address) for a key(collateral address)
            oracles[underlyings[i]] = _oracles[i];
            // Assign the value(collateral address) for a key(collateral name ENUM)
            assetAddress[IBorrowing.AssetName(i + 1)] = underlyings[i];
        }
    }

    /**
     * @dev get the usd value of ETH and exchange rate for collaterals
     * @param underlying Collateral token address
     */
    function _price(
        address underlying
    ) internal view returns (uint128, uint128) {
        // if there is no oracles found revert
        if (oracles[underlying] == address(0))
            revert("Price oracle not found for this underlying token address.");

        // get oracles based on chain
        if(block.chainid == 31337 || block.chainid == 34443){ //?  31337 is used for testing
            // for we are using redstone oracles
            IRedstoneOracle oracle = IRedstoneOracle(oracles[underlying]);
            // updating the underlying to address supported by redstone, based on underlying type
            if (underlying == assetAddress[IBorrowing.AssetName.WeETH]) {
                underlying = 0x028227c4dd1e5419d11Bb6fa6e661920c519D4F5;
            } else if (underlying == assetAddress[IBorrowing.AssetName.WrsETH]) {
                underlying = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
            } else if (underlying == assetAddress[IBorrowing.AssetName.ETH]) {
                underlying = address(0);
            }

            // get the price of the underlying
            uint256 priceInUsd = oracle.priceOf(underlying);
            // get the eth price
            uint256 priceOfNativeInUsd = oracle.priceOfETH();
            // return the exchange rate of the underlying to the ETH and eth price
            return (uint128((priceInUsd * 1e18) / priceOfNativeInUsd), uint128(priceOfNativeInUsd / 1e16));
        } else if (block.chainid == 10) {
            AggregatorV3Interface oracle = AggregatorV3Interface(oracles[underlying]);

            // Get the eth price
            (, int256 price_, , , ) = oracle.latestRoundData();
            // If the token is ETH
            if (underlying == assetAddress[IBorrowing.AssetName.ETH]) {
                // Return Exchange rate as 1 and ETH price with 2 decimals
                return (1 ether, uint128((uint256(price_) / 1e6)));
            } else {
                (, uint128 ethPrice) = _price(assetAddress[IBorrowing.AssetName.ETH]);
                // Return Exchange rate and ETH price with 2 decimals
                return (uint128(uint256(price_)), ethPrice);
            }
        } else {
            return (0, 0);
        }
    }
    
    /**
     * @dev get the usd value of ETH and exchange rate for collaterals
     * @param underlying Collateral token address
     */
    function price(
        address underlying
    ) external view override returns (uint128, uint128) {
        return _price(underlying);
    }
}