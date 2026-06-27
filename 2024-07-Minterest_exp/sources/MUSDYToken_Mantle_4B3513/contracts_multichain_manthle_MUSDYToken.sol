// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

// solhint-disable max-line-length
/*
_/\\\\____________/\\\\___/\\\\\\\\\\\___/\\\\\_____/\\\___/\\\\\\\\\\\\\\\___/\\\\\\\\\\\\\\\_____/\\\\\\\\\_______/\\\\\\\\\\\\\\\______/\\\\\\\\\\\_____/\\\\\\\\\\\\\\\_
 _\/\\\\\\________/\\\\\\__\/////\\\///___\/\\\\\\___\/\\\__\///////\\\/////___\/\\\///////////____/\\\///////\\\____\/\\\///////////_____/\\\/////////\\\__\///////\\\/////__
  _\/\\\//\\\____/\\\//\\\______\/\\\______\/\\\/\\\__\/\\\________\/\\\________\/\\\______________\/\\\_____\/\\\____\/\\\_______________\//\\\______\///_________\/\\\_______
   _\/\\\\///\\\/\\\/_\/\\\______\/\\\______\/\\\//\\\_\/\\\________\/\\\________\/\\\\\\\\\\\______\/\\\\\\\\\\\/_____\/\\\\\\\\\\\________\////\\\________________\/\\\_______
    _\/\\\__\///\\\/___\/\\\______\/\\\______\/\\\\//\\\\/\\\________\/\\\________\/\\\///////_______\/\\\//////\\\_____\/\\\///////____________\////\\\_____________\/\\\_______
     _\/\\\____\///_____\/\\\______\/\\\______\/\\\_\//\\\/\\\________\/\\\________\/\\\______________\/\\\____\//\\\____\/\\\______________________\////\\\__________\/\\\_______
      _\/\\\_____________\/\\\______\/\\\______\/\\\__\//\\\\\\________\/\\\________\/\\\______________\/\\\_____\//\\\___\/\\\_______________/\\\______\//\\\_________\/\\\_______
       _\/\\\_____________\/\\\___/\\\\\\\\\\\__\/\\\___\//\\\\\________\/\\\________\/\\\\\\\\\\\\\\\__\/\\\______\//\\\__\/\\\\\\\\\\\\\\\__\///\\\\\\\\\\\/__________\/\\\_______
        _\///______________\///___\///////////___\///_____\/////_________\///_________\///////////////___\///________\///___\///////////////_____\///////////____________\///________
*/

import "./MUSDYTokenV1.sol";

/**
 * @title Minterest MUSDYToken Contract
 * @author Minterest
 * @dev Provides access to market operations using USDY and rUSDY tokens
 */
contract MUSDYToken is MUSDYTokenV1 {
    /// @inheritdoc IMUSDYToken
    function lendRUSDY(uint256 _rUsdyLendAmount) external override {
        accrueInterest();
        supervisor.beforeLend(this, msg.sender);

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), ErrorCodes.MARKET_NOT_FRESH);

        // Order of actions here is crucial
        // 1. Calculate exchange rate based on parammeters before user's action
        uint256 exchangeRateMantissa = exchangeRateStoredInternal();
        // 2. Transfer USDY tokens from sender to the market contract (changes market's total cash)
        uint256 usdyLendAmount = unwrapTokens(_rUsdyLendAmount, msg.sender);
        // 3. Calculate amount of MTokens to mint
        uint256 lendTokens = (usdyLendAmount * EXP_SCALE) / exchangeRateMantissa;

        uint256 newTotalTokenSupply = totalTokenSupply + lendTokens;
        totalTokenSupply = newTotalTokenSupply;
        accountTokens[msg.sender] += lendTokens;

        emit Lend(msg.sender, usdyLendAmount, lendTokens, newTotalTokenSupply);
        emit Transfer(address(0), msg.sender, lendTokens);
    }
}
