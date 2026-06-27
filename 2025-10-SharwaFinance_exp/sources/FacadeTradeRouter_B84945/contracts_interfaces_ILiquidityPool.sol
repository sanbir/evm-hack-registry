// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidityPool is IERC20{

    // ONLY MANAGER_ROLE FUNCTIONS //

    /**
     * @notice Sets the maximum pool capacity.
     * @param newMaximumPoolCapacity The new maximum capacity of the pool.
     */
    function setMaximumPoolCapacity(uint newMaximumPoolCapacity) external;

    /**
     * @notice Sets the maximum borrow multiplier.
     * @param newMaximumBorrowMultiplier The new maximum borrow multiplier.
     */
    function setMaximumBorrowMultiplier(uint newMaximumBorrowMultiplier) external;

    /**
     * @notice Sets the insurance pool address.
     * @param newInsurancePool The new address of the insurance pool.
     */        
    function setInsurancePool(address newInsurancePool) external;

    /**
     * @notice Sets the insurance rate multiplier.
     * @param newInsuranceRateMultiplier The new insurance rate multiplier.
     */    
    function setInsuranceRateMultiplier(uint newInsuranceRateMultiplier) external;

    /**
     * @notice Sets the interest rate.
     * @param newInterestRate The new interest rate.
     */    
    function setInterestRate(uint newInterestRate) external;

    // EXTERNAL FUNCTIONS //

    /**
     * @notice Adds liquidity to the current pool.
     * @param amount The deposit amount expressed in poolToken.
     */
    function provide(uint amount) external;

    /**
     * @notice Removes liquidity from the current pool.
     * @param amount The removing amount expressed in shareToken.
     */
    function withdraw(uint amount) external;

    /**
     * @notice Borrows from a liquidity pool.
     * @param marginAccountID The number of the ERC-721 token, which is a margin account.
     * @param amount The loan amount denominated in poolToken.
     */    
	function borrow(uint marginAccountID, uint amount) external;

    /**
     * @notice Returns the debt to the pool.
     * @param marginAccountID The number of the ERC-721 token, which is a margin account.
     * @param amount The loan amount denominated in poolToken.
     */    
	function repay(uint marginAccountID, uint amount) external;

    // VIEW FUNCTIONS //

    /**
     * @notice Returns the amount of the debt, including interest, for a given time.
     * @param marginAccountID The number of the ERC-721 token, which is a margin account.
     * @param checkTime The future time in seconds.
     * @return debtByPool The amount of debt including interest in poolToken.
     */
    function getDebtWithAccruedInterestOnTime(uint marginAccountID, uint checkTime) external view returns (uint debtByPool);

    /**
     * @notice Returns the amount of the debt, including interest.
     * @param marginAccountID The number of the ERC-721 token, which is a margin account.
     * @return debtByPool The amount of debt including interest in poolToken.
     */    
	function getDebtWithAccruedInterest(uint marginAccountID) external view returns (uint debtByPool);

    /**
     * @notice Returns the total amount of borrows, including interest.
     * @return totalBorrows The amount of total borrows including interest in poolToken.
     */    
    function totalBorrows() external view returns (uint);

    /**
     * @notice Returns the total amount of tokens in the liquidity pool including current trade.
     * @return value The total liquidity.
     */    
    function getTotalLiquidity() external view returns (uint);

    // PUBLIC FUNCTIONS //

    function maximumBorrowMultiplier() external returns (uint maximumBorrowMultiplier);

    // EVENTS //

    /**
     * @dev Emitted when the maximum pool capacity is updated.
     * @param newMaximumPoolCapacity The new maximum pool capacity.
     */
    event UpdateMaximumPoolCapacity(
        uint newMaximumPoolCapacity
    );

    /**
     * @dev Emitted when the maximum borrow multiplier is updated.
     * @param newMaximumBorrowMultiplier The new maximum borrow multiplier.
     */
    event UpdateMaximumBorrowMultiplier(
        uint newMaximumBorrowMultiplier
    );

    /**
     * @dev Emitted when the insurance pool address is updated.
     * @param newInsurancePool The new address of the insurance pool.
     */
    event UpdateInsurancePool(
        address newInsurancePool
    );

    /**
     * @dev Emitted when the insurance rate multiplier is updated.
     * @param newInsuranceRateMultiplier The new insurance rate multiplier.
     */
    event UpdateInsuranceRateMultiplier(
        uint newInsuranceRateMultiplier
    );

    /**
     * @dev Emitted when liquidity is provided to the pool.
     * @param liquidityProvider The address of the liquidity provider.
     * @param amountAddedShareTokens The amount of share tokens minted to the provider.
     * @param amountDepositPoolTokens The amount of pool tokens deposited.
     */
    event Provide(
        address indexed liquidityProvider,
        uint amountAddedShareTokens,
        uint amountDepositPoolTokens
    );

    /**
     * @dev Emitted when liquidity is withdrawn from the pool.
     * @param liquidityProvider The address of the liquidity provider.
     * @param amountBurnedShareTokens The amount of share tokens burned from the provider.
     * @param amountWithdrawPoolTokens The amount of pool tokens withdrawn.
     */
    event Withdraw(
        address indexed liquidityProvider,
        uint amountBurnedShareTokens,
        uint amountWithdrawPoolTokens
    );

    /**
     * @dev Emitted when the interest rate is updated.
     * @param totalLiquidity The total liquidity in the pool.
     * @param totalBorrows The total borrows including interest.
     * @param interestRate The new interest rate.
     */
    event UpdateInterestRate(
        uint totalLiquidity,
        uint totalBorrows,
        uint interestRate
    );

    /**
     * @dev Emitted when a loan is borrowed from the pool.
     * @param marginAccountID The ID of the margin account.
     * @param amountDebtTokens The amount of debt tokens borrowed.
     */
    event Borrow(
        uint indexed marginAccountID, 
        uint amountDebtTokens);

    /**
     * @dev Emitted when a loan is repaid to the pool.
     * @param marginAccountID The ID of the margin account.
     * @param amountRepayDebtTokens The amount of debt tokens repaid.
     * @param accruedInterest The accrued interest repaid.
     */
    event Repay(
        uint indexed marginAccountID,
        uint amountRepayDebtTokens,
        uint accruedInterest,
        uint profitInsurancePool
    );
}