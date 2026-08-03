// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICurvePool} from "./ICurvePool.sol";

/**
 * @title Curve proxy contract interface
 * @notice Adds/Removes liquidity to Curve pools
 */
interface ICurve {
    /**
     * @notice Emitted when a token is deposited to a Curve pool
     * @param _caller Address of the caller of the transaction
     * @param _pool The address of the Curve pool
     */
    event Deposit(address _caller, address _pool);

    /**
     * @notice Emitted when a token is withdrawn from a Curve pool
     * @param _caller Address of the caller of the transaction
     * @param _pool The address of the Curve pool
     */
    event Withdraw(address _caller, address _pool);

    /**
     * @notice Adds liquidity to a pool
     * @param _amounts Amounts of the tokens in the pool to deposit
     * @param _minMintAmount Minimum amount of LP tokens to mint from the deposit
     * @param _pool Address of the pool
     * @param _proxyFeeInWei Fee of the proxy contract
     */
    function deposit(uint256[2] calldata _amounts, uint256 _minMintAmount, ICurvePool _pool, uint256 _proxyFeeInWei)
        external
        payable;

    /**
     * @notice Withdraw token from the pool
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _minAmounts Minimum amounts of underlying tokens to receive
     * @param _pool Address of the pool
     */
    function withdraw(uint256 _amount, uint256[2] calldata _minAmounts, ICurvePool _pool) external payable;

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinI(uint256 _amount, int128 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received);

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinU(uint256 _amount, uint256 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received);
}
