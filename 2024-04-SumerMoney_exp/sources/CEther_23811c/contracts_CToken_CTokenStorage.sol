// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import './Interfaces/ICToken.sol';

abstract contract CTokenStorage is ICToken {
  bool public isCToken;
  bool public isCEther;
  /// @dev Guard variable for re-entrancy checks
  bool internal _notEntered;

  /// @notice Underlying asset for this CToken
  address public underlying;

  /// @notice EIP-20 token name for this token
  string public name;

  /// @notice EIP-20 token symbol for this token
  string public symbol;

  /// @notice EIP-20 token decimals for this token
  uint8 public decimals;

  /// @dev Maximum borrow rate that can ever be applied (.0005% / block)
  uint256 internal constant BORROW_RATE_MAX_MANTISSA = 0.0005e16;

  /// @dev Maximum fraction of interest that can be set aside for reserves
  uint256 internal constant RESERVE_FACTOR_MAX_MANTISSA = 1e18;

  /// @notice Administrator for this contract
  address payable public admin;

  /// @notice Pending administrator for this contract
  address payable public pendingAdmin;

  /// @notice Contract which oversees inter-cToken operations
  address public comptroller;

  /// @notice Model which tells what the current interest rate should be
  address public interestRateModel;

  /// @dev Initial exchange rate used when minting the first CTokens (used when totalSupply = 0)
  uint256 internal initialExchangeRateMantissa;

  /// @notice Fraction of interest currently set aside for reserves
  uint256 public reserveFactorMantissa;

  /// @notice Block number that interest was last accrued at
  uint256 public override accrualBlockNumber;

  /// @notice Accumulator of the total earned interest rate since the opening of the market
  uint256 public borrowIndex;

  /// @notice Total amount of outstanding borrows of the underlying in this market
  uint256 public totalBorrows;

  /// @notice Total amount of reserves of the underlying held in this market
  uint256 public totalReserves;

  /// @notice Total number of tokens in circulation
  uint256 public override totalSupply;

  /// @dev Official record of token balances for each account
  mapping(address => uint256) internal accountTokens;

  /// @dev Approved token transfer amounts on behalf of others
  mapping(address => mapping(address => uint256)) internal transferAllowances;

  /// @notice Container for borrow balance information
  /// @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
  /// @member interestIndex Global borrowIndex as of the most recent balance-changing action
  struct BorrowSnapshot {
    uint256 principal;
    uint256 interestIndex;
  }

  /// @dev Mapping of account addresses to outstanding borrow balances
  mapping(address => BorrowSnapshot) internal accountBorrows;

  /// @notice Share of seized collateral that is added to reserves
  uint256 public constant protocolSeizeShareMantissa = 30e16; //30% of profit

  uint256 public discountRateMantissa = 1e18;

  uint256 public underlyingBalance;
}
