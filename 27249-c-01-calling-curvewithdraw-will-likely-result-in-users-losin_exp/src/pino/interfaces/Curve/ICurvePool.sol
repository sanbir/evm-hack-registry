// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/**
 * @title Curve Pool interface
 * @author Curve.Fi
 * @notice Minimal pool implementation with no lending
 */
interface ICurvePool {
    /**
     * @notice Deposit coins into the pool
     * @param _amounts List of amounts of coins to deposit
     * @param _min_mint_amount Minimum amount of LP tokens to mint from the deposit
     */
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable;

    /**
     * @notice Withdraw coins from the pool
     * @dev Withdrawal amounts are based on current deposit ratios
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _min_amounts Minimum amounts of underlying coins to receive
     */
    function remove_liquidity(uint256 _amount, uint256[2] calldata _min_amounts) external;

    /**
     * @notice Withdraw a single coin from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _i Index value of the coin to withdraw
     * @param _min Minimum amount of coin to receive
     * @return Amount of coin received
     */
    function remove_liquidity_one_coin(uint256 _amount, uint256 _i, uint256 _min) external returns (uint256);

    /**
     * @notice Withdraw a single coin from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _i Index value of the coin to withdraw
     * @param _min Minimum amount of coin to receive
     * @return Amount of coin received
     */
    function remove_liquidity_one_coin(uint256 _amount, int128 _i, uint256 _min) external returns (uint256);
}
