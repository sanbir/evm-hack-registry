// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "../../../interfaces/IMToken.sol";
import "../../../interfaces/ISupervisor.sol";
import "./IrUSDY.sol";

/**
 * @title Minterest MUSDYToken Contract
 * @author Minterest
 * @dev Provides access to market operations using USDY and rUSDY tokens
 */
interface IMUSDYToken is IMToken {
    /**
     * @notice Allows to lend rUSDY token in exchange for USDY token.
     *         Internally converts received rUSDY tokens to USDY and lends it to the market.
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param _rUsdyLendAmount The number of rUSDY tokens to lend
     */
    function lendRUSDY(uint256 _rUsdyLendAmount) external;

    /**
     * @notice Allows to redeem USDY tokens in exchange for rUSDY.
     *         As output redeemer receives equivalent of redeem amount in rUSDY tokens
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of mUSDY ( market wrap tokens ) to redeem
     */
    function redeemRUSDY(uint256 redeemTokens) external;

    /**
     * @notice Allows to redeem USDY tokens in exchange for rUSDY.
     *         As output redeemer receives equivalent of redeem amount in rUSDY tokens
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param _usdyRedeemAmount The number of USDY tokens to redeem
     */
    function redeemUnderlyingRUSDY(uint256 _usdyRedeemAmount) external;

    /**
     * @notice Allows to borrow USDY from the protocol to their own address
     *         As output borrower receives equivalent of borrow amount in rUSDY tokens
     * @param _usdyBorrowAmount The amount of USDY tokens to borrow
     */
    function borrowRUSDY(uint256 _usdyBorrowAmount) external;

    /**
     * @notice Allows to repay their own borrow in form of rUSDY tokens.
     *         Actual repay amount in USDY tokens is calculated based on latest rUSDY/USDY exchange rate
     * @dev _rUsdyRepayAmount The amount of rUSDY tokens to repay
     */
    function repayBorrowRUSDY(uint256 _rUsdyRepayAmount) external;
}
