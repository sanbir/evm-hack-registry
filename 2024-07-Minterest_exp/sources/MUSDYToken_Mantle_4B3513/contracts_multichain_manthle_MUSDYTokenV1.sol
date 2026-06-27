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

import "./interfaces/IrUSDY.sol";
import "./interfaces/IMUSDYToken.sol";
import "../../MToken.sol";

/**
 * @title Minterest MUSDYToken Contract
 * @author Minterest
 * @dev Provides access to market operations using USDY and rUSDY tokens
 */
contract MUSDYTokenV1 is IMUSDYToken, MToken {
    using SafeERC20 for IrUSDY;
    using SafeERC20 for IERC20;

    IrUSDY public rUSDY;

    function _initialize(
        address admin_,
        ISupervisor supervisor_,
        IInterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IERC20 underlying_,
        IrUSDY wrapper_
    ) external {
        rUSDY = wrapper_;

        super.initialize(
            admin_,
            supervisor_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_,
            underlying_
        );
    }

    /// @inheritdoc IMUSDYToken
    function lendRUSDY(uint256 _rUsdyLendAmount) external virtual {
        accrueInterest();
        uint256 usdyLendAmount = unwrapTokens(_rUsdyLendAmount, msg.sender);
        lendFresh(msg.sender, usdyLendAmount, false);
    }

    /// @inheritdoc IMUSDYToken
    function redeemRUSDY(uint256 _redeemTokens) external {
        accrueInterest();
        uint256 usdyRedeemAmount = redeemFresh(msg.sender, _redeemTokens, 0, false, false);
        wrapTokens(usdyRedeemAmount, msg.sender);
    }

    /// @inheritdoc IMUSDYToken
    function redeemUnderlyingRUSDY(uint256 _usdyRedeemAmount) external {
        accrueInterest();
        uint256 usdyRedeemAmount = redeemFresh(msg.sender, 0, _usdyRedeemAmount, false, false);
        wrapTokens(usdyRedeemAmount, msg.sender);
    }

    /// @inheritdoc IMUSDYToken
    function borrowRUSDY(uint256 _usdyBorrowAmount) external {
        accrueInterest();
        borrowFresh(_usdyBorrowAmount, false);
        wrapTokens(_usdyBorrowAmount, msg.sender);
    }

    /// @inheritdoc IMUSDYToken
    function repayBorrowRUSDY(uint256 _rUsdyRepayAmount) external {
        accrueInterest();
        uint256 usdyRepayAmount = unwrapTokens(_rUsdyRepayAmount, msg.sender);
        repayBorrowFresh(msg.sender, msg.sender, usdyRepayAmount, false);
    }

    /**
     * @notice Transfers token from sender to the market contract and converts rUSDY tokens to USDY
     * @param rUSDYAmount Amount of rUSDY tokens to transfer
     * @param sender The address of the account that provide rUSDY tokens
     */
    function unwrapTokens(uint256 rUSDYAmount, address sender) internal returns (uint256 usdyAmount) {
        rUSDY.safeTransferFrom(sender, address(this), rUSDYAmount);

        uint256 balanceBefore = underlying.balanceOf(address(this));

        rUSDY.unwrap(rUSDYAmount);

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = underlying.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, ErrorCodes.TOKEN_TRANSFER_IN_UNDERFLOW);

        usdyAmount = balanceAfter - balanceBefore;
    }

    /**
     * @notice Converts rUSDY tokens to USDY and transfers from market contract to the receiver address
     * @param USDYAmount Amount of USDY tokens to convert
     * @param receiver The address of the account that receives rUSDY tokens
     */
    function wrapTokens(uint256 USDYAmount, address receiver) internal returns (uint256 rUsdyAmount) {
        uint256 balanceBefore = rUSDY.balanceOf(address(this));

        underlying.safeApprove(address(rUSDY), USDYAmount);
        rUSDY.wrap(USDYAmount);

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = rUSDY.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, ErrorCodes.TOKEN_TRANSFER_IN_UNDERFLOW);

        rUsdyAmount = balanceAfter - balanceBefore;

        rUSDY.safeTransfer(receiver, rUsdyAmount);
    }
}
