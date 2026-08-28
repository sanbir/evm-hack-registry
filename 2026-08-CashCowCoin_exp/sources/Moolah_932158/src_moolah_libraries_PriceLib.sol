// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MarketParams, Id, Position, Market, IMoolah } from "../interfaces/IMoolah.sol";
import { SharesMathLib } from "./SharesMathLib.sol";
import { UtilsLib } from "./UtilsLib.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IBroker } from "../../broker/interfaces/IBroker.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library PriceLib {
  using UtilsLib for uint256;
  using SharesMathLib for uint256;

  /// @dev Returns the price of the collateral asset in terms of the loan asset
  /// @notice if there is a broker for the market and user address is non-zero
  ///         will return a price which might deviates from the market price according to user's position
  /// @param marketParams The market parameters
  /// @param user The user address
  /// @param broker The broker address
  /// @return basePrice The price of the collateral asset
  /// @return quotePrice The price of the loan asset
  /// @return baseTokenDecimals The decimals of the collateral asset
  /// @return quoteTokenDecimals The decimals of the loan asset
  function _getPrice(
    MarketParams memory marketParams,
    address user,
    address broker
  ) public view returns (uint256 basePrice, uint256 quotePrice, uint256 baseTokenDecimals, uint256 quoteTokenDecimals) {
    IOracle _oracle = IOracle(marketParams.oracle);
    baseTokenDecimals = IERC20Metadata(marketParams.collateralToken).decimals();
    quoteTokenDecimals = IERC20Metadata(marketParams.loanToken).decimals();

    // if market has broker and user address is non-zero
    if (broker != address(0) && user != address(0)) {
      // get price from broker
      // price deviates with user's position at broker
      IBroker _broker = IBroker(broker);
      basePrice = _broker.peek(marketParams.collateralToken, user);
      quotePrice = _broker.peek(marketParams.loanToken, user);
    } else {
      // else return market price from oracle
      basePrice = _oracle.peek(marketParams.collateralToken);
      quotePrice = _oracle.peek(marketParams.loanToken);
    }
  }

  /// @dev returns the total debt amount owed to the broker by the borrower
  /// @param id The market id
  /// @param borrower The address of the borrower
  /// @param moolah The address of the Moolah contract
  /// @return totalDebt The total debt amount owed to the broker
  function _getBrokerTotalDebt(Id id, address borrower, address moolah) public view returns (uint256) {
    IMoolah _moolah = IMoolah(moolah);
    // get broker address
    address brokerAddress = _moolah.brokers(id);
    // return 0 if no broker
    if (brokerAddress == address(0) || borrower == address(0)) {
      return 0;
    }
    // get debt at broker
    return IBroker(brokerAddress).getUserTotalDebt(borrower);
  }
}
