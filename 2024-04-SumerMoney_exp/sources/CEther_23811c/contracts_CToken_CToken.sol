// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import '../Comptroller/Interfaces/IComptroller.sol';
import '../Comptroller/Interfaces/IPriceOracle.sol';
import './Interfaces/IInterestRateModel.sol';
import './TokenErrorReporter.sol';
import './CTokenStorage.sol';
import '../Exponential/Exponential.sol';

uint256 constant expScale = 1e18;

/**
 * @title Compound's CToken Contract
 * @notice Abstract base for CTokens
 * @author Compound
 */
abstract contract CToken is CTokenStorage {
  using Exponential for uint256;
  using Exponential for Exp;
  using ExponentialNoError for uint256;
  using ExponentialNoError for Exp;
  using CarefulMath for uint256;
  using TokenErrorReporter for Error;

  modifier onlyAdmin() {
    // Check caller is admin
    require(msg.sender == admin, 'UNAUTHORIZED');
    _;
  }

  /**
   * @notice Initialize the money market
   * @param comptroller_ The address of the Comptroller
   * @param interestRateModel_ The address of the interest rate model
   * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
   * @param name_ EIP-20 name of this token
   * @param symbol_ EIP-20 symbol of this token
   * @param decimals_ EIP-20 decimal precision of this token
   */
  function initialize(
    address comptroller_,
    address interestRateModel_,
    uint256 initialExchangeRateMantissa_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    bool isCToken_,
    address payable _admin,
    uint256 discountRateMantissa_
  ) internal {
    admin = _admin;
    require(accrualBlockNumber == 0 && borrowIndex == 0, 'MMOB'); // market may only be initialized once

    isCToken = isCToken_;

    // Set initial exchange rate
    initialExchangeRateMantissa = initialExchangeRateMantissa_;
    require(initialExchangeRateMantissa > 0, 'IERM'); // initial exchange rate must be greater than zero

    discountRateMantissa = discountRateMantissa_;
    require(discountRateMantissa > 0 && discountRateMantissa <= 1e18, 'RMI'); // rate must in [0,100]

    // Set the comptroller
    // Set market's comptroller to newComptroller
    comptroller = comptroller_;

    // Emit NewComptroller(oldComptroller, newComptroller)
    emit NewComptroller(address(0), comptroller_);

    // Initialize block number and borrow index (block number mocks depend on comptroller being set)
    accrualBlockNumber = getBlockNumber();
    borrowIndex = 1e18;

    // Set the interest rate model (depends on block number / borrow index)
    interestRateModel = interestRateModel_;
    emit NewMarketInterestRateModel(address(0), interestRateModel_);

    name = name_;
    symbol = symbol_;
    decimals = decimals_;

    // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
    _notEntered = true;
  }

  /**
   * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
   * @dev Called by both `transfer` and `transferFrom` internally
   * @param spender The address of the account performing the transfer
   * @param src The address of the source account
   * @param dst The address of the destination account
   * @param tokens The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transferTokens(address spender, address src, address dst, uint256 tokens) internal returns (uint256) {
    /* Fail if transfer not allowed */
    uint256 allowed = IComptroller(comptroller).transferAllowed(address(this), src, dst, tokens);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.TRANSFER_COMPTROLLER_REJECTION, allowed);
    }

    /* Do not allow self-transfers */
    if (src == dst) {
      Error.BAD_INPUT.fail(FailureInfo.TRANSFER_NOT_ALLOWED);
    }

    /* Get the allowance, infinite for the account owner */
    uint256 startingAllowance = 0;
    if (spender == src) {
      startingAllowance = uint256(0);
    } else {
      startingAllowance = transferAllowances[src][spender];
    }

    /* Do the calculations, checking for {under,over}flow */
    MathError mathErr;
    uint256 allowanceNew;
    uint256 srcTokensNew;
    uint256 dstTokensNew;

    (mathErr, allowanceNew) = startingAllowance.subUInt(tokens);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.TRANSFER_NOT_ALLOWED);
    }

    (mathErr, srcTokensNew) = accountTokens[src].subUInt(tokens);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.TRANSFER_NOT_ENOUGH);
    }

    (mathErr, dstTokensNew) = accountTokens[dst].addUInt(tokens);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.TRANSFER_TOO_MUCH);
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    accountTokens[src] = srcTokensNew;
    accountTokens[dst] = dstTokensNew;

    /* Eat some of the allowance (if necessary) */
    if (startingAllowance != uint256(0)) {
      transferAllowances[src][spender] = allowanceNew;
    }

    /* We emit a Transfer event */
    emit Transfer(src, dst, tokens);

    // unused function
    // comptroller.transferVerify(address(this), src, dst, tokens);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Transfer `amount` tokens from `msg.sender` to `dst`
   * @param dst The address of the destination account
   * @param amount The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transfer(address dst, uint256 amount) external override nonReentrant returns (bool) {
    return transferTokens(msg.sender, msg.sender, dst, amount) == uint256(Error.NO_ERROR);
  }

  /**
   * @notice Transfer `amount` tokens from `src` to `dst`
   * @param src The address of the source account
   * @param dst The address of the destination account
   * @param amount The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transferFrom(address src, address dst, uint256 amount) external override nonReentrant returns (bool) {
    return transferTokens(msg.sender, src, dst, amount) == uint256(Error.NO_ERROR);
  }

  /**
   * @notice Approve `spender` to transfer up to `amount` from `src`
   * @dev This will overwrite the approval amount for `spender`
   *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
   * @param spender The address of the account which may transfer tokens
   * @param amount The number of tokens that are approved (-1 means infinite)
   * @return Whether or not the approval succeeded
   */
  function approve(address spender, uint256 amount) external override returns (bool) {
    address src = msg.sender;
    transferAllowances[src][spender] = amount;
    emit Approval(src, spender, amount);
    return true;
  }

  /**
   * @notice Get the current allowance from `owner` for `spender`
   * @param owner The address of the account which owns the tokens to be spent
   * @param spender The address of the account which may transfer tokens
   * @return The number of tokens allowed to be spent (-1 means infinite)
   */
  function allowance(address owner, address spender) external view override returns (uint256) {
    return transferAllowances[owner][spender];
  }

  /**
   * @notice Get the token balance of the `owner`
   * @param owner The address of the account to query
   * @return The number of tokens owned by `owner`
   */
  function balanceOf(address owner) external view override returns (uint256) {
    return accountTokens[owner];
  }

  /**
   * @notice Get the underlying balance of the `owner`
   * @dev This also accrues interest in a transaction
   * @param owner The address of the account to query
   * @return The amount of underlying owned by `owner`
   */
  function balanceOfUnderlying(address owner) external override returns (uint256) {
    Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
    (MathError mErr, uint256 balance) = exchangeRate.mulScalarTruncate(accountTokens[owner]);
    if (mErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.BALANCE_COULD_NOT_BE_CALCULATED);
    }
    return balance;
  }

  /**
   * @notice Get a snapshot of the account's balances, and the cached exchange rate
   * @dev This is used by comptroller to more efficiently perform liquidity checks.
   * @param account Address of the account to snapshot
   * @return (possible error, token balance, borrow balance, exchange rate mantissa)
   */
  function getAccountSnapshot(address account) external view override returns (uint256, uint256, uint256, uint256) {
    uint256 cTokenBalance = accountTokens[account];
    uint256 borrowBalance;
    uint256 exchangeRateMantissa;

    MathError mErr;

    (mErr, borrowBalance) = borrowBalanceStoredInternal(account);
    if (mErr != MathError.NO_ERROR) {
      return (uint256(Error.MATH_ERROR), 0, 0, 0);
    }

    (mErr, exchangeRateMantissa) = exchangeRateStoredInternal();
    if (mErr != MathError.NO_ERROR) {
      return (uint256(Error.MATH_ERROR), 0, 0, 0);
    }

    return (uint256(Error.NO_ERROR), cTokenBalance, borrowBalance, exchangeRateMantissa);
  }

  /**
   * @dev Function to simply retrieve block number
   *  This exists mainly for inheriting test contracts to stub this result.
   */
  function getBlockNumber() internal view returns (uint256) {
    return block.number;
  }

  /**
   * @notice Returns the current per-block borrow interest rate for this cToken
   * @return The borrow interest rate per block, scaled by 1e18
   */
  function borrowRatePerBlock() external view override returns (uint256) {
    return IInterestRateModel(interestRateModel).getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
  }

  /**
   * @notice Returns the current per-block supply interest rate for this cToken
   * @return The supply interest rate per block, scaled by 1e18
   */
  function supplyRatePerBlock() external view override returns (uint256) {
    return
      IInterestRateModel(interestRateModel).getSupplyRate(
        getCashPrior(),
        totalBorrows,
        totalReserves,
        reserveFactorMantissa
      );
  }

  /**
   * @notice Returns the current total borrows plus accrued interest
   * @return The total borrows with interest
   */
  function totalBorrowsCurrent() external override nonReentrant returns (uint256) {
    accrueInterest();
    return totalBorrows;
  }

  /**
   * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
   * @param account The address whose balance should be calculated after updating borrowIndex
   * @return The calculated balance
   */
  function borrowBalanceCurrent(address account) external override nonReentrant returns (uint256) {
    accrueInterest();
    return borrowBalanceStored(account);
  }

  /**
   * @notice Return the borrow balance of account based on stored data
   * @param account The address whose balance should be calculated
   * @return The calculated balance
   */
  function borrowBalanceStored(address account) public view override returns (uint256) {
    (MathError err, uint256 result) = borrowBalanceStoredInternal(account);
    if (err != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.BORROW_BALANCE_STORED_INTERNAL_FAILED);
    }
    return result;
  }

  /**
   * @notice Return the borrow balance of account based on stored data
   * @param account The address whose balance should be calculated
   * @return (error code, the calculated balance or 0 if error code is non-zero)
   */
  function borrowBalanceStoredInternal(address account) internal view returns (MathError, uint256) {
    /* Note: we do not assert that the market is up to date */
    MathError mathErr;
    uint256 principalTimesIndex;
    uint256 result;

    /* Get borrowBalance and borrowIndex */
    BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

    /* If borrowBalance = 0 then borrowIndex is likely also 0.
     * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
     */
    if (borrowSnapshot.principal == 0) {
      return (MathError.NO_ERROR, 0);
    }

    /* Calculate new borrow balance using the interest index:
     *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
     */
    (mathErr, principalTimesIndex) = borrowSnapshot.principal.mulUInt(borrowIndex);
    if (mathErr != MathError.NO_ERROR) {
      return (mathErr, 0);
    }

    (mathErr, result) = principalTimesIndex.divUInt(borrowSnapshot.interestIndex);
    if (mathErr != MathError.NO_ERROR) {
      return (mathErr, 0);
    }

    return (MathError.NO_ERROR, result);
  }

  /**
   * @notice Accrue interest then return the up-to-date exchange rate
   * @return Calculated exchange rate scaled by 1e18
   */
  function exchangeRateCurrent() public override nonReentrant returns (uint256) {
    accrueInterest();
    return exchangeRateStored();
  }

  /**
   * @notice Calculates the exchange rate from the underlying to the CToken
   * @dev This function does not accrue interest before calculating the exchange rate
   * @return Calculated exchange rate scaled by 1e18
   */
  function exchangeRateStored() public view override returns (uint256) {
    (MathError err, uint256 result) = exchangeRateStoredInternal();
    if (err != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.EXCHANGE_RATE_STORED_INTERNAL_FAILED);
    }
    return result;
  }

  /**
   * @notice Calculates the exchange rate from the underlying to the CToken
   * @dev This function does not accrue interest before calculating the exchange rate
   * @return (error code, calculated exchange rate scaled by 1e18)
   */
  function exchangeRateStoredInternal() internal view returns (MathError, uint256) {
    if (!isCToken) {
      return (MathError.NO_ERROR, initialExchangeRateMantissa);
    }

    uint256 _totalSupply = totalSupply;
    if (_totalSupply == 0) {
      /*
       * If there are no tokens minted:
       *  exchangeRate = initialExchangeRate
       */
      return (MathError.NO_ERROR, initialExchangeRateMantissa);
    } else {
      /*
       * Otherwise:
       *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
       */
      uint256 totalCash = getCashPrior();
      uint256 cashPlusBorrowsMinusReserves;
      Exp memory exchangeRate;
      MathError mathErr;

      (mathErr, cashPlusBorrowsMinusReserves) = totalCash.addThenSubUInt(totalBorrows, totalReserves);
      if (mathErr != MathError.NO_ERROR) {
        return (mathErr, 0);
      }

      (mathErr, exchangeRate) = cashPlusBorrowsMinusReserves.getExp(_totalSupply);
      if (mathErr != MathError.NO_ERROR) {
        return (mathErr, 0);
      }

      return (MathError.NO_ERROR, exchangeRate.mantissa);
    }
  }

  /**
   * @notice Get cash balance of this cToken in the underlying asset
   * @return The quantity of underlying asset owned by this contract
   */
  function getCash() external view override returns (uint256) {
    return getCashPrior();
  }

  /**
   * @notice Applies accrued interest to total borrows and reserves
   * @dev This calculates interest accrued from the last checkpointed block
   *   up to the current block and writes new checkpoint to storage.
   */
  function accrueInterest() public virtual override returns (uint256) {
    /* Remember the initial block number */
    uint256 currentBlockNumber = getBlockNumber();
    uint256 accrualBlockNumberPrior = accrualBlockNumber;

    /* Short-circuit accumulating 0 interest */
    if (accrualBlockNumberPrior == currentBlockNumber) {
      return uint256(Error.NO_ERROR);
    }

    /* Read the previous values out of storage */
    uint256 cashPrior = getCashPrior();
    uint256 borrowsPrior = totalBorrows;
    uint256 reservesPrior = totalReserves;
    uint256 borrowIndexPrior = borrowIndex;

    /* Calculate the current borrow interest rate */
    uint256 borrowRateMantissa = IInterestRateModel(interestRateModel).getBorrowRate(
      cashPrior,
      borrowsPrior,
      reservesPrior
    );
    if (borrowRateMantissa > BORROW_RATE_MAX_MANTISSA) {
      // Error.TOKEN_ERROR.failOpaque(FailureInfo.BORROW_RATE_ABSURDLY_HIGH, borrowRateMantissa);
      borrowRateMantissa = BORROW_RATE_MAX_MANTISSA;
    }

    /* Calculate the number of blocks elapsed since the last accrual */
    (MathError mathErr, uint256 blockDelta) = currentBlockNumber.subUInt(accrualBlockNumberPrior);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.COULD_NOT_CACULATE_BLOCK_DELTA);
    }

    /*
     * Calculate the interest accumulated into borrows and reserves and the new index:
     *  simpleInterestFactor = borrowRate * blockDelta
     *  interestAccumulated = simpleInterestFactor * totalBorrows
     *  totalBorrowsNew = interestAccumulated + totalBorrows
     *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
     *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
     */

    Exp memory simpleInterestFactor;
    uint256 interestAccumulated;
    uint256 totalBorrowsNew;
    uint256 totalReservesNew;
    uint256 borrowIndexNew;

    (mathErr, simpleInterestFactor) = Exp({mantissa: borrowRateMantissa}).mulScalar(blockDelta);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(
        FailureInfo.ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED,
        uint256(mathErr)
      );
    }

    (mathErr, interestAccumulated) = simpleInterestFactor.mulScalarTruncate(borrowsPrior);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(
        FailureInfo.ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED,
        uint256(mathErr)
      );
    }

    (mathErr, totalBorrowsNew) = interestAccumulated.addUInt(borrowsPrior);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED, uint256(mathErr));
    }

    (mathErr, totalReservesNew) = Exp({mantissa: reserveFactorMantissa}).mulScalarTruncateAddUInt(
      interestAccumulated,
      reservesPrior
    );
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED, uint256(mathErr));
    }

    (mathErr, borrowIndexNew) = simpleInterestFactor.mulScalarTruncateAddUInt(borrowIndexPrior, borrowIndexPrior);
    if (mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED, uint256(mathErr));
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    accrualBlockNumber = currentBlockNumber;
    borrowIndex = borrowIndexNew;
    totalBorrows = totalBorrowsNew;
    totalReserves = totalReservesNew;

    /* We emit an AccrueInterest event */
    emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param mintAmount The amount of the underlying asset to supply
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
   */
  function mintInternal(uint256 mintAmount) internal nonReentrant returns (uint256, uint256) {
    accrueInterest();
    // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
    return mintFresh(msg.sender, mintAmount);
  }

  struct MintLocalVars {
    Error err;
    MathError mathErr;
    uint256 exchangeRateMantissa;
    uint256 mintTokens;
    uint256 totalSupplyNew;
    uint256 accountTokensNew;
    uint256 actualMintAmount;
  }

  /**
   * @notice User supplies assets into the market and receives cTokens in exchange
   * @dev Assumes interest has already been accrued up to the current block
   * @param minter The address of the account which is supplying the assets
   * @param mintAmount The amount of the underlying asset to supply
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
   */
  function mintFresh(address minter, uint256 mintAmount) internal returns (uint256, uint256) {
    /* Fail if mint not allowed */
    uint256 allowed = IComptroller(comptroller).mintAllowed(address(this), minter, mintAmount);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.MINT_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.MINT_FRESHNESS_CHECK);
    }

    MintLocalVars memory vars;

    (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.MINT_EXCHANGE_RATE_READ_FAILED, uint256(vars.mathErr));
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     *  We call `doTransferIn` for the minter and the mintAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
     *  side-effects occurred. The function returns the amount actually transferred,
     *  in case of a fee. On success, the cToken holds an additional `actualMintAmount`
     *  of cash.
     */
    vars.actualMintAmount = doTransferIn(minter, mintAmount);

    /*
     * We get the current exchange rate and calculate the number of cTokens to be minted:
     *  mintTokens = actualMintAmount / exchangeRate
     */

    (vars.mathErr, vars.mintTokens) = vars.actualMintAmount.divScalarByExpTruncate(
      Exp({mantissa: vars.exchangeRateMantissa})
    );
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.MINT_EXCHANGE_CALCULATION_FAILED);
    }

    /*
     * We calculate the new total supply of cTokens and minter token balance, checking for overflow:
     *  totalSupplyNew = totalSupply + mintTokens
     *  accountTokensNew = accountTokens[minter] + mintTokens
     */
    (vars.mathErr, vars.totalSupplyNew) = totalSupply.addUInt(vars.mintTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.MINT_NEW_TOTAL_SUPPLY_CALCULATION_FAILED);
    }

    (vars.mathErr, vars.accountTokensNew) = accountTokens[minter].addUInt(vars.mintTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.MINT_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED);
    }

    /* We write previously calculated values into storage */
    totalSupply = vars.totalSupplyNew;
    accountTokens[minter] = vars.accountTokensNew;

    /* We emit a Mint event, and a Transfer event */
    emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
    emit Transfer(address(this), minter, vars.mintTokens);

    /* We call the defense hook */
    // unused function
    // comptroller.mintVerify(address(this), minter, vars.actualMintAmount, vars.mintTokens);

    return (uint256(Error.NO_ERROR), vars.actualMintAmount);
  }

  /**
   * @notice Sender redeems cTokens in exchange for the underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemTokens The number of cTokens to redeem into underlying
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function redeemInternal(uint256 redeemTokens) internal nonReentrant returns (uint256) {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    return redeemFresh(payable(msg.sender), redeemTokens, 0);
  }

  /**
   * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemAmount The amount of underlying to receive from redeeming cTokens
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function redeemUnderlyingInternal(uint256 redeemAmount) internal nonReentrant returns (uint256) {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    return redeemFresh(payable(msg.sender), 0, redeemAmount);
  }

  struct RedeemLocalVars {
    Error err;
    MathError mathErr;
    uint256 exchangeRateMantissa;
    uint256 redeemTokens;
    uint256 redeemAmount;
    uint256 totalSupplyNew;
    uint256 accountTokensNew;
  }

  /**
   * @notice User redeems cTokens in exchange for the underlying asset
   * @dev Assumes interest has already been accrued up to the current block
   * @param redeemer The address of the account which is redeeming the tokens
   * @param redeemTokensIn The number of cTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
   * @param redeemAmountIn The number of underlying tokens to receive from redeeming cTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function redeemFresh(
    address payable redeemer,
    uint256 redeemTokensIn,
    uint256 redeemAmountIn
  ) internal returns (uint256) {
    if (redeemTokensIn != 0 && redeemAmountIn != 0) {
      Error.BAD_INPUT.fail(FailureInfo.ONE_OF_REDEEM_TOKENS_IN_OR_REDEEM_AMOUNT_IN_MUST_BE_ZERO);
    }
    RedeemLocalVars memory vars;

    /* exchangeRate = invoke Exchange Rate Stored() */
    (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_RATE_READ_FAILED, uint256(vars.mathErr));
    }

    /* If redeemTokensIn > 0: */
    if (redeemTokensIn > 0) {
      /*
       * We calculate the exchange rate and the amount of underlying to be redeemed:
       *  redeemTokens = redeemTokensIn
       *  redeemAmount = redeemTokensIn x exchangeRateCurrent
       */
      vars.redeemTokens = redeemTokensIn;

      (vars.mathErr, vars.redeemAmount) = Exp({mantissa: vars.exchangeRateMantissa}).mulScalarTruncate(redeemTokensIn);
      if (vars.mathErr != MathError.NO_ERROR) {
        Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_TOKENS_CALCULATION_FAILED, uint256(vars.mathErr));
      }
    } else {
      /*
       * We get the current exchange rate and calculate the amount to be redeemed:
       *  redeemTokens = redeemAmountIn / exchangeRate
       *  redeemAmount = redeemAmountIn
       */

      (vars.mathErr, vars.redeemTokens) = redeemAmountIn.divScalarByExpTruncate(
        Exp({mantissa: vars.exchangeRateMantissa})
      );
      if (vars.mathErr != MathError.NO_ERROR) {
        Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_AMOUNT_CALCULATION_FAILED, uint256(vars.mathErr));
      }

      vars.redeemAmount = redeemAmountIn;
    }

    /* Fail if redeem not allowed */
    uint256 allowed = IComptroller(comptroller).redeemAllowed(address(this), redeemer, vars.redeemTokens);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.REDEEM_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.REDEEM_FRESHNESS_CHECK);
    }

    /*
     * We calculate the new total supply and redeemer balance, checking for underflow:
     *  totalSupplyNew = totalSupply - redeemTokens
     *  accountTokensNew = accountTokens[redeemer] - redeemTokens
     */
    (vars.mathErr, vars.totalSupplyNew) = totalSupply.subUInt(vars.redeemTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_NEW_TOTAL_SUPPLY_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    (vars.mathErr, vars.accountTokensNew) = accountTokens[redeemer].subUInt(vars.redeemTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    /* Fail gracefully if protocol has insufficient cash */
    if (isCToken && (getCashPrior() < vars.redeemAmount)) {
      Error.TOKEN_INSUFFICIENT_CASH.fail(FailureInfo.REDEEM_TRANSFER_OUT_NOT_POSSIBLE);
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write previously calculated values into storage */
    totalSupply = vars.totalSupplyNew;
    accountTokens[redeemer] = vars.accountTokensNew;

    /*
     * We invoke doTransferOut for the redeemer and the redeemAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken has redeemAmount less of cash.
     *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
     */
    // doTransferOut(redeemer, vars.redeemAmount);
    transferToTimelock(false, redeemer, vars.redeemAmount);

    /* We emit a Transfer event, and a Redeem event */
    emit Transfer(redeemer, address(this), vars.redeemTokens);
    emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

    /* We call the defense hook */
    IComptroller(comptroller).redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

    return uint256(Error.NO_ERROR);
  }

  function redeemAndTransferFresh(address payable redeemer, uint256 redeemTokensIn) internal returns (uint256) {
    if (redeemTokensIn == 0) {
      Error.BAD_INPUT.fail(FailureInfo.ONE_OF_REDEEM_TOKENS_IN_OR_REDEEM_AMOUNT_IN_MUST_BE_ZERO);
    }
    RedeemLocalVars memory vars;

    /* exchangeRate = invoke Exchange Rate Stored() */
    (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_RATE_READ_FAILED, uint256(vars.mathErr));
    }
    /*
     * We calculate the exchange rate and the amount of underlying to be redeemed:
     *  redeemTokens = redeemTokensIn
     *  redeemAmount = redeemTokensIn x exchangeRateCurrent
     */
    vars.redeemTokens = redeemTokensIn;

    (vars.mathErr, vars.redeemAmount) = Exp({mantissa: vars.exchangeRateMantissa}).mulScalarTruncate(redeemTokensIn);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_TOKENS_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    /* Fail if redeem not allowed */
    uint256 allowed = IComptroller(comptroller).redeemAllowed(address(this), redeemer, vars.redeemTokens);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.REDEEM_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.REDEEM_FRESHNESS_CHECK);
    }

    /*
     * We calculate the new total supply and redeemer balance, checking for underflow:
     *  totalSupplyNew = totalSupply - redeemTokens
     *  accountTokensNew = accountTokens[redeemer] - redeemTokens
     */
    (vars.mathErr, vars.totalSupplyNew) = totalSupply.subUInt(vars.redeemTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_NEW_TOTAL_SUPPLY_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    (vars.mathErr, vars.accountTokensNew) = accountTokens[redeemer].subUInt(vars.redeemTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    /* Fail gracefully if protocol has insufficient cash */
    if (isCToken && (getCashPrior() < vars.redeemAmount)) {
      Error.TOKEN_INSUFFICIENT_CASH.fail(FailureInfo.REDEEM_TRANSFER_OUT_NOT_POSSIBLE);
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write previously calculated values into storage */
    totalSupply = vars.totalSupplyNew;
    accountTokens[redeemer] = vars.accountTokensNew;

    /*
     * We invoke doTransferOut for the redeemer and the redeemAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken has redeemAmount less of cash.
     *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
     */
    doTransferOut(redeemer, vars.redeemAmount);

    /* We emit a Transfer event, and a Redeem event */
    emit Transfer(redeemer, address(this), vars.redeemTokens);
    emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

    /* We call the defense hook */
    IComptroller(comptroller).redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function borrowInternal(uint256 borrowAmount) internal nonReentrant returns (uint256) {
    accrueInterest();
    // borrowFresh emits borrow-specific logs on errors, so we don't need to
    return borrowFresh(payable(msg.sender), borrowAmount);
  }

  struct BorrowLocalVars {
    MathError mathErr;
    uint256 accountBorrows;
    uint256 accountBorrowsNew;
    uint256 totalBorrowsNew;
  }

  /**
   * @notice Users borrow assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function borrowFresh(address payable borrower, uint256 borrowAmount) internal returns (uint256) {
    /* Fail if borrow not allowed */
    uint256 allowed = IComptroller(comptroller).borrowAllowed(address(this), borrower, borrowAmount);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.BORROW_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.BORROW_FRESHNESS_CHECK);
    }

    /* Fail gracefully if protocol has insufficient underlying cash */
    if (isCToken && (getCashPrior() < borrowAmount)) {
      Error.TOKEN_INSUFFICIENT_CASH.fail(FailureInfo.BORROW_CASH_NOT_AVAILABLE);
    }

    BorrowLocalVars memory vars;

    /*
     * We calculate the new borrower and total borrow balances, failing on overflow:
     *  accountBorrowsNew = accountBorrows + borrowAmount
     *  totalBorrowsNew = totalBorrows + borrowAmount
     */
    (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(borrower);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    (vars.mathErr, vars.accountBorrowsNew) = vars.accountBorrows.addUInt(borrowAmount);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(
        FailureInfo.BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED,
        uint256(vars.mathErr)
      );
    }

    (vars.mathErr, vars.totalBorrowsNew) = totalBorrows.addUInt(borrowAmount);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED, uint256(vars.mathErr));
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = vars.accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = vars.totalBorrowsNew;

    /*
     * We invoke doTransferOut for the borrower and the borrowAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken borrowAmount less of cash.
     *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
     */
    // doTransferOut(borrower, borrowAmount);
    transferToTimelock(true, borrower, borrowAmount);

    /* We emit a Borrow event */
    emit Borrow(borrower, borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

    /* We call the defense hook */
    // unused function
    // comptroller.borrowVerify(address(this), borrower, borrowAmount);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Sender repays their own borrow
   * @param repayAmount The amount to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowInternal(uint256 repayAmount) internal nonReentrant returns (uint256, uint256) {
    accrueInterest();
    // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
    return repayBorrowFresh(msg.sender, msg.sender, repayAmount);
  }

  /**
   * @notice Sender repays a borrow belonging to borrower
   * @param borrower the account with the debt being paid off
   * @param repayAmount The amount to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowBehalfInternal(
    address borrower,
    uint256 repayAmount
  ) internal nonReentrant returns (uint256, uint256) {
    accrueInterest();
    // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
    return repayBorrowFresh(msg.sender, borrower, repayAmount);
  }

  struct RepayBorrowLocalVars {
    Error err;
    MathError mathErr;
    uint256 repayAmount;
    uint256 borrowerIndex;
    uint256 accountBorrows;
    uint256 accountBorrowsNew;
    uint256 totalBorrowsNew;
    uint256 actualRepayAmount;
  }

  /**
   * @notice Borrows are repaid by another user (possibly the borrower).
   * @param payer the account paying off the borrow
   * @param borrower the account with the debt being paid off
   * @param repayAmount the amount of underlying tokens being returned
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowFresh(address payer, address borrower, uint256 repayAmount) internal returns (uint256, uint256) {
    /* Fail if repayBorrow not allowed */
    uint256 allowed = IComptroller(comptroller).repayBorrowAllowed(address(this), payer, borrower, repayAmount);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.REPAY_BORROW_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.REPAY_BORROW_FRESHNESS_CHECK);
    }

    RepayBorrowLocalVars memory vars;

    /* We remember the original borrowerIndex for verification purposes */
    vars.borrowerIndex = accountBorrows[borrower].interestIndex;

    /* We fetch the amount the borrower owes, with accumulated interest */
    (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(borrower);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(
        FailureInfo.REPAY_BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED,
        uint256(vars.mathErr)
      );
    }

    /* If repayAmount == -1, repayAmount = accountBorrows */
    if (repayAmount == ~uint256(0)) {
      vars.repayAmount = vars.accountBorrows;
    } else {
      vars.repayAmount = repayAmount;
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     * We call doTransferIn for the payer and the repayAmount
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken holds an additional repayAmount of cash.
     *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
     *   it returns the amount actually transferred, in case of a fee.
     */
    vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount);

    /*
     * We calculate the new borrower and total borrow balances, failing on underflow:
     *  accountBorrowsNew = accountBorrows - actualRepayAmount
     *  totalBorrowsNew = totalBorrows - actualRepayAmount
     */
    (vars.mathErr, vars.accountBorrowsNew) = vars.accountBorrows.subUInt(vars.actualRepayAmount);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.REPAY_BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED);
    }

    (vars.mathErr, vars.totalBorrowsNew) = totalBorrows.subUInt(vars.actualRepayAmount);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.fail(FailureInfo.REPAY_BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED);
    }

    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = vars.accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = vars.totalBorrowsNew;

    /* We emit a RepayBorrow event */
    emit RepayBorrow(payer, borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

    /* We call the defense hook */
    // unused function
    // comptroller.repayBorrowVerify(address(this), payer, borrower, vars.actualRepayAmount, vars.borrowerIndex);

    return (uint256(Error.NO_ERROR), vars.actualRepayAmount);
  }

  /**
   * @notice The sender liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @param borrower The borrower of this cToken to be liquidated
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   * @param repayAmount The amount of the underlying borrowed asset to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function liquidateBorrowInternal(
    address borrower,
    uint256 repayAmount,
    address cTokenCollateral
  ) internal nonReentrant returns (uint256, uint256) {
    accrueInterest();
    ICToken(cTokenCollateral).accrueInterest();

    // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
    return liquidateBorrowFresh(msg.sender, borrower, repayAmount, cTokenCollateral);
  }

  /**
   * @notice The liquidator liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @param borrower The borrower of this cToken to be liquidated
   * @param liquidator The address repaying the borrow and seizing collateral
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   * @param repayAmount The amount of the underlying borrowed asset to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function liquidateBorrowFresh(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    address cTokenCollateral
  ) internal returns (uint256, uint256) {
    /* Fail if liquidate not allowed */
    uint256 allowed = liquidateBorrowAllowed(address(cTokenCollateral), liquidator, borrower, repayAmount);
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.LIQUIDATE_COMPTROLLER_REJECTION, allowed);
    }

    /* Verify market's block number equals current block number */
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.LIQUIDATE_FRESHNESS_CHECK);
    }

    /* Verify cTokenCollateral market's block number equals current block number */
    if (ICToken(cTokenCollateral).accrualBlockNumber() != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.LIQUIDATE_COLLATERAL_FRESHNESS_CHECK);
    }

    /* Fail if borrower = liquidator */
    if (borrower == liquidator) {
      Error.INVALID_ACCOUNT_PAIR.fail(FailureInfo.LIQUIDATE_LIQUIDATOR_IS_BORROWER);
    }

    /* Fail if repayAmount = 0 */
    if (repayAmount == 0) {
      Error.INVALID_CLOSE_AMOUNT_REQUESTED.fail(FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_ZERO);
    }

    if (repayAmount == ~uint256(0)) {
      Error.INVALID_CLOSE_AMOUNT_REQUESTED.fail(FailureInfo.LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX);
    }

    /* Fail if repayBorrow fails */
    (, uint256 actualRepayAmount) = repayBorrowFresh(liquidator, borrower, repayAmount);

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We calculate the number of collateral tokens that will be seized */
    (, uint256 seizeTokens, uint256 seizeProfitTokens) = liquidateCalculateSeizeTokens(
      cTokenCollateral,
      actualRepayAmount
    );

    /* Revert if borrower collateral token balance < seizeTokens */
    if (ICToken(cTokenCollateral).balanceOf(borrower) < seizeTokens) {
      Error.TOKEN_ERROR.fail(FailureInfo.LIQUIDATE_SEIZE_TOO_MUCH);
    }

    // If this is also the collateral, run seizeInternal to avoid re-entrancy, otherwise make an external call
    if (cTokenCollateral == address(this)) {
      seizeInternal(address(this), liquidator, borrower, seizeTokens, seizeProfitTokens);
    } else {
      ICToken(cTokenCollateral).seize(liquidator, borrower, seizeTokens, seizeProfitTokens);
    }

    /* We emit a LiquidateBorrow event */
    emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(cTokenCollateral), seizeTokens);

    /* We call the defense hook */
    // unused function
    // comptroller.liquidateBorrowVerify(address(this), address(cTokenCollateral), liquidator, borrower, actualRepayAmount, seizeTokens);

    return (uint256(Error.NO_ERROR), actualRepayAmount);
  }

  /**
   * @notice Transfers collateral tokens (this market) to the liquidator.
   * @dev Will fail unless called by another cToken during the process of liquidation.
   *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
   * @param liquidator The account receiving seized collateral
   * @param borrower The account having collateral seized
   * @param seizeTokens The number of cTokens to seize
   * @param seizeProfitTokens The number of cToken to seize as profit
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function seize(
    address liquidator,
    address borrower,
    uint256 seizeTokens,
    uint256 seizeProfitTokens
  ) external override nonReentrant returns (uint256) {
    return seizeInternal(msg.sender, liquidator, borrower, seizeTokens, seizeProfitTokens);
  }

  struct SeizeInternalLocalVars {
    MathError mathErr;
    uint256 borrowerTokensNew;
    uint256 liquidatorTokensNew;
    uint256 liquidatorSeizeTokens;
    uint256 protocolSeizeTokens;
    uint256 protocolSeizeAmount;
    uint256 exchangeRateMantissa;
    uint256 totalReservesNew;
    uint256 totalSupplyNew;
  }

  /**
   * @notice Transfers collateral tokens (this market) to the liquidator.
   * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another CToken.
   *  Its absolutely critical to use msg.sender as the seizer cToken and not a parameter.
   * @param seizerToken The contract seizing the collateral (i.e. borrowed cToken)
   * @param liquidator The account receiving seized collateral
   * @param borrower The account having collateral seized
   * @param seizeTokens The number of cTokens to seize
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function seizeInternal(
    address seizerToken,
    address liquidator,
    address borrower,
    uint256 seizeTokens,
    uint256 seizeProfitTokens
  ) internal returns (uint256) {
    /* Fail if seize not allowed */
    uint256 allowed = IComptroller(comptroller).seizeAllowed(
      address(this),
      seizerToken,
      liquidator,
      borrower,
      seizeTokens
    );
    if (allowed != 0) {
      Error.COMPTROLLER_REJECTION.failOpaque(FailureInfo.LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, allowed);
    }

    /* Fail if borrower = liquidator */
    if (borrower == liquidator) {
      Error.INVALID_ACCOUNT_PAIR.fail(FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
    }

    SeizeInternalLocalVars memory vars;

    /*
     * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
     *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
     *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
     */
    (vars.mathErr, vars.borrowerTokensNew) = accountTokens[borrower].subUInt(seizeTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.LIQUIDATE_SEIZE_BALANCE_DECREMENT_FAILED, uint256(vars.mathErr));
    }

    vars.protocolSeizeTokens = seizeProfitTokens.mul_(Exp({mantissa: protocolSeizeShareMantissa}));
    vars.liquidatorSeizeTokens = seizeTokens.sub_(vars.protocolSeizeTokens);

    (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.REDEEM_EXCHANGE_RATE_READ_FAILED, uint256(vars.mathErr));
    }

    vars.protocolSeizeAmount = Exp({mantissa: vars.exchangeRateMantissa}).mul_ScalarTruncate(vars.protocolSeizeTokens);

    vars.totalReservesNew = totalReserves.add_(vars.protocolSeizeAmount);
    vars.totalSupplyNew = totalSupply.sub_(vars.protocolSeizeTokens);

    (vars.mathErr, vars.liquidatorTokensNew) = accountTokens[liquidator].addUInt(vars.liquidatorSeizeTokens);
    if (vars.mathErr != MathError.NO_ERROR) {
      Error.MATH_ERROR.failOpaque(FailureInfo.LIQUIDATE_SEIZE_BALANCE_INCREMENT_FAILED, uint256(vars.mathErr));
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    totalReserves = vars.totalReservesNew;
    totalSupply = vars.totalSupplyNew;
    accountTokens[borrower] = vars.borrowerTokensNew;
    accountTokens[liquidator] = vars.liquidatorTokensNew;

    /* Emit a Transfer event */
    emit Transfer(borrower, liquidator, vars.liquidatorSeizeTokens);
    emit Transfer(borrower, address(this), vars.protocolSeizeTokens);
    emit ReservesAdded(address(this), vars.protocolSeizeAmount, vars.totalReservesNew);

    /* We call the defense hook */
    // unused function
    // comptroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

    redeemAndTransferFresh(payable(liquidator), vars.liquidatorSeizeTokens);

    return uint256(Error.NO_ERROR);
  }

  /*** Admin Functions ***/

  /**
   * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
   * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
   * @param newPendingAdmin New pending admin.
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setPendingAdmin(address payable newPendingAdmin) external override onlyAdmin returns (uint256) {
    // Save current value, if any, for inclusion in log
    address oldPendingAdmin = pendingAdmin;

    // Store pendingAdmin with value newPendingAdmin
    require(newPendingAdmin != address(0), 'AIZ'); // Address is Zero
    pendingAdmin = newPendingAdmin;

    // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
    emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
   * @dev Admin function for pending admin to accept role and update admin
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _acceptAdmin() external override returns (uint256) {
    // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
    if (msg.sender != pendingAdmin || msg.sender == address(0)) {
      Error.UNAUTHORIZED.fail(FailureInfo.ACCEPT_ADMIN_PENDING_ADMIN_CHECK);
    }

    // Save current values for inclusion in log
    address oldAdmin = admin;
    address oldPendingAdmin = pendingAdmin;

    // Store admin with value pendingAdmin
    admin = pendingAdmin;

    // Clear the pending value
    pendingAdmin = payable(0);

    emit NewAdmin(oldAdmin, admin);
    emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Sets a new comptroller for the market
   * @dev Admin function to set a new comptroller
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setComptroller(address newComptroller) public override onlyAdmin returns (uint256) {
    address oldComptroller = comptroller;
    // Ensure invoke comptroller.isComptroller() returns true
    require(IComptroller(newComptroller).isComptroller(), 'MMRF'); // market method returned false

    // Set market's comptroller to newComptroller
    comptroller = newComptroller;

    // Emit NewComptroller(oldComptroller, newComptroller)
    emit NewComptroller(oldComptroller, newComptroller);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
   * @dev Admin function to accrue interest and set a new reserve factor
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setReserveFactor(uint256 newReserveFactorMantissa) external override nonReentrant returns (uint256) {
    accrueInterest();
    // _setReserveFactorFresh emits reserve-factor-specific logs on errors, so we don't need to.
    return _setReserveFactorFresh(newReserveFactorMantissa);
  }

  /**
   * @notice Sets a new reserve factor for the protocol (*requires fresh interest accrual)
   * @dev Admin function to set a new reserve factor
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setReserveFactorFresh(uint256 newReserveFactorMantissa) internal onlyAdmin returns (uint256) {
    // Verify market's block number equals current block number
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.SET_RESERVE_FACTOR_FRESH_CHECK);
    }

    // Check newReserveFactor ≤ maxReserveFactor
    if (newReserveFactorMantissa > RESERVE_FACTOR_MAX_MANTISSA) {
      Error.BAD_INPUT.fail(FailureInfo.SET_RESERVE_FACTOR_BOUNDS_CHECK);
    }

    uint256 oldReserveFactorMantissa = reserveFactorMantissa;
    reserveFactorMantissa = newReserveFactorMantissa;

    emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice Accrues interest and reduces reserves by transferring from msg.sender
   * @param addAmount Amount of addition to reserves
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _addReservesInternal(uint256 addAmount) internal nonReentrant returns (uint256) {
    accrueInterest();
    // _addReservesFresh emits reserve-addition-specific logs on errors, so we don't need to.
    (uint256 error, ) = _addReservesFresh(addAmount);
    return error;
  }

  /**
   * @notice Add reserves by transferring from caller
   * @dev Requires fresh interest accrual
   * @param addAmount Amount of addition to reserves
   * @return (uint, uint) An error code (0=success, otherwise a failure (see ErrorReporter.sol for details)) and the actual amount added, net token fees
   */
  function _addReservesFresh(uint256 addAmount) internal returns (uint256, uint256) {
    // totalReserves + actualAddAmount
    uint256 totalReservesNew;
    uint256 actualAddAmount;

    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.ADD_RESERVES_FRESH_CHECK);
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     * We call doTransferIn for the caller and the addAmount
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken holds an additional addAmount of cash.
     *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
     *  it returns the amount actually transferred, in case of a fee.
     */

    actualAddAmount = doTransferIn(msg.sender, addAmount);

    totalReservesNew = totalReserves + actualAddAmount;

    /* Revert on overflow */
    if (totalReservesNew < totalReserves) {
      Error.MATH_ERROR.fail(FailureInfo.ADD_RESERVES_UNEXPECTED_OVERFLOW);
    }

    // Store reserves[n+1] = reserves[n] + actualAddAmount
    totalReserves = totalReservesNew;

    /* Emit NewReserves(admin, actualAddAmount, reserves[n+1]) */
    emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

    /* Return (NO_ERROR, actualAddAmount) */
    return (uint256(Error.NO_ERROR), actualAddAmount);
  }

  /**
   * @notice Accrues interest and reduces reserves by transferring to admin
   * @param reduceAmount Amount of reduction to reserves
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _reduceReserves(uint256 reduceAmount) external override nonReentrant returns (uint256) {
    accrueInterest();
    // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
    return _reduceReservesFresh(reduceAmount);
  }

  /**
   * @notice Reduces reserves by transferring to admin
   * @dev Requires fresh interest accrual
   * @param reduceAmount Amount of reduction to reserves
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _reduceReservesFresh(uint256 reduceAmount) internal onlyAdmin returns (uint256) {
    // totalReserves - reduceAmount
    uint256 totalReservesNew;

    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.REDUCE_RESERVES_FRESH_CHECK);
    }

    // Fail gracefully if protocol has insufficient underlying cash
    if (getCashPrior() < reduceAmount) {
      Error.TOKEN_INSUFFICIENT_CASH.fail(FailureInfo.REDUCE_RESERVES_CASH_NOT_AVAILABLE);
    }

    // Check reduceAmount ≤ reserves[n] (totalReserves)
    if (reduceAmount > totalReserves) {
      Error.BAD_INPUT.fail(FailureInfo.REDUCE_RESERVES_VALIDATION);
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    totalReservesNew = totalReserves - reduceAmount;
    // We checked reduceAmount <= totalReserves above, so this should never revert.
    if (totalReservesNew < totalReserves) {
      Error.MATH_ERROR.fail(FailureInfo.ADD_RESERVES_UNEXPECTED_OVERFLOW);
    }

    // Store reserves[n+1] = reserves[n] - reduceAmount
    totalReserves = totalReservesNew;

    // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
    doTransferOut(admin, reduceAmount);

    emit ReservesReduced(admin, reduceAmount, totalReservesNew);

    return uint256(Error.NO_ERROR);
  }

  /**
   * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
   * @dev Admin function to accrue interest and update the interest rate model
   * @param newInterestRateModel the new interest rate model to use
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setInterestRateModel(address newInterestRateModel) public override returns (uint256) {
    accrueInterest();
    // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
    return _setInterestRateModelFresh(newInterestRateModel);
  }

  /**
   * @notice updates the interest rate model (*requires fresh interest accrual)
   * @dev Admin function to update the interest rate model
   * @param newInterestRateModel the new interest rate model to use
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setInterestRateModelFresh(address newInterestRateModel) internal onlyAdmin returns (uint256) {
    // Used to store old model for use in the event that is emitted on success
    address oldInterestRateModel;
    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockNumber != getBlockNumber()) {
      Error.MARKET_NOT_FRESH.fail(FailureInfo.SET_INTEREST_RATE_MODEL_FRESH_CHECK);
    }

    // Track the market's current interest rate model
    oldInterestRateModel = interestRateModel;

    // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
    require(IInterestRateModel(interestRateModel).isInterestRateModel(), 'MMRF'); // market method returned false

    // Set the interest rate model to newInterestRateModel
    interestRateModel = newInterestRateModel;

    // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
    emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);

    return uint256(Error.NO_ERROR);
  }

  function _syncUnderlyingBalance() external onlyAdmin {
    underlyingBalance = ICToken(underlying).balanceOf(address(this));
  }

  /*** Safe Token ***/

  /**
   * @notice Gets balance of this contract in terms of the underlying
   * @dev This excludes the value of the current message, if any
   * @return The quantity of underlying owned by this contract
   */
  function getCashPrior() internal view virtual returns (uint256);

  /**
   * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
   *  This may revert due to insufficient balance or insufficient allowance.
   */
  function doTransferIn(address from, uint256 amount) internal virtual returns (uint256);

  /**
   * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
   *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
   *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
   */
  function doTransferOut(address payable to, uint256 amount) internal virtual;

  function transferToTimelock(bool isBorrow, address to, uint256 amount) internal virtual;

  /*** Reentrancy Guard ***/

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   */
  modifier nonReentrant() {
    require(_notEntered, 'RE'); // re-entered
    _notEntered = false;
    _;
    _notEntered = true; // get a gas-refund post-Istanbul
  }

  /**
   * @notice Returns true if the given cToken market has been deprecated
   * @dev All borrows in a deprecated cToken market can be immediately liquidated
   */
  function isDeprecated() public view returns (bool) {
    return
      IComptroller(comptroller).marketGroupId(address(this)) == 0 &&
      //borrowGuardianPaused[cToken] == true &&
      IComptroller(comptroller)._getBorrowPaused(address(this)) &&
      reserveFactorMantissa == 1e18;
  }

  /**
   * @notice Checks if the liquidation should be allowed to occur
   * @param cTokenCollateral Asset which was used as collateral and will be seized
   * @param liquidator The address repaying the borrow and seizing the collateral
   * @param borrower The address of the borrower
   * @param repayAmount The amount of underlying being repaid
   */
  function liquidateBorrowAllowed(
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) public view returns (uint256) {
    // Shh - currently unused:
    liquidator;
    if (!IComptroller(comptroller).isListed(address(this)) || !IComptroller(comptroller).isListed(cTokenCollateral)) {
      Error.MARKET_NOT_LISTED.fail(FailureInfo.MARKET_NOT_LISTED);
    }

    (, uint256 borrowBalance) = borrowBalanceStoredInternal(borrower);

    /* allow accounts to be liquidated if the market is deprecated */
    if (isDeprecated()) {
      if (borrowBalance < repayAmount) {
        Error.TOKEN_ERROR.fail(FailureInfo.TOO_MUCH_REPAY);
      }
    } else {
      /* The borrower must have shortfall in order to be liquidatable */
      (, , uint256 shortfall) = IComptroller(comptroller).getHypotheticalAccountLiquidity(
        borrower,
        address(this),
        0,
        0
      );

      if (shortfall <= 0) {
        Error.TOKEN_ERROR.fail(FailureInfo.INSUFFICIENT_SHORTFALL);
      }

      /* The liquidator may not repay more than what is allowed by the closeFactor */
      uint256 maxClose = Exp({mantissa: IComptroller(comptroller).closeFactorMantissa()}).mul_ScalarTruncate(
        borrowBalance
      );
      if (repayAmount > maxClose) {
        Error.TOKEN_ERROR.fail(FailureInfo.TOO_MUCH_REPAY);
      }
    }
    return uint256(0);
  }

  /**
   * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
   * @dev Used in liquidation (called in ICToken(cToken).liquidateBorrowFresh)
   * @param cTokenCollateral The address of the collateral cToken
   * @param actualRepayAmount The amount of cTokenBorrowed underlying to convert into cTokenCollateral tokens
   * @return (errorCode, number of cTokenCollateral tokens to be seized in a liquidation, number of cTokenCollateral tokens to be seized as profit in a liquidation)
   */
  function liquidateCalculateSeizeTokens(
    address cTokenCollateral,
    uint256 actualRepayAmount
  ) public view returns (uint256, uint256, uint256) {
    (bool repayListed, uint8 repayTokenGroupId, ) = IComptroller(comptroller).markets(address(this));
    require(repayListed, 'repay token not listed');
    (bool seizeListed, uint8 seizeTokenGroupId, ) = IComptroller(comptroller).markets(cTokenCollateral);
    require(seizeListed, 'seize token not listed');

    (
      uint256 heteroLiquidationIncentive,
      uint256 homoLiquidationIncentive,
      uint256 sutokenLiquidationIncentive
    ) = IComptroller(comptroller).liquidationIncentiveMantissa();

    // default is repaying heterogeneous assets
    uint256 liquidationIncentiveMantissa = heteroLiquidationIncentive;
    if (repayTokenGroupId == seizeTokenGroupId) {
      if (CToken(address(this)).isCToken() == false) {
        // repaying sutoken
        liquidationIncentiveMantissa = sutokenLiquidationIncentive;
      } else {
        // repaying homogeneous assets
        liquidationIncentiveMantissa = homoLiquidationIncentive;
      }
    }

    /* Read oracle prices for borrowed and collateral markets */
    address oracle = IComptroller(comptroller).oracle();
    uint256 priceBorrowedMantissa = IPriceOracle(oracle).getUnderlyingPrice(address(address(this)));
    uint256 priceCollateralMantissa = IPriceOracle(oracle).getUnderlyingPrice(address(cTokenCollateral));
    if (priceBorrowedMantissa <= 0 || priceCollateralMantissa <= 0) {
      Error.TOKEN_ERROR.fail(FailureInfo.PRICE_ERROR);
    }
    /*
     * Get the exchange rate and calculate the number of collateral tokens to seize:
     *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
     *  seizeTokens = seizeAmount / exchangeRate
     *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
     */
    uint256 exchangeRateMantissa = ICToken(cTokenCollateral).exchangeRateStored(); // Note: reverts on error
    uint256 seizeTokenDecimal = CToken(cTokenCollateral).decimals();
    uint256 repayTokenDecimal = CToken(address(this)).decimals();

    uint256 seizeTokens;
    Exp memory numerator;
    Exp memory denominator;
    Exp memory ratio;

    uint256 seizeProfitTokens;
    Exp memory profitRatio;
    Exp memory profitNumerator;

    numerator = Exp({mantissa: liquidationIncentiveMantissa + expScale}).mul_(Exp({mantissa: priceBorrowedMantissa}));
    if (repayTokenDecimal < 18) {
      numerator = numerator.mul_(10 ** (18 - repayTokenDecimal));
    }

    profitNumerator = Exp({mantissa: liquidationIncentiveMantissa}).mul_(Exp({mantissa: priceBorrowedMantissa}));
    if (repayTokenDecimal < 18) {
      profitNumerator = profitNumerator.mul_(10 ** (18 - repayTokenDecimal));
    }

    denominator = Exp({mantissa: priceCollateralMantissa}).mul_(Exp({mantissa: exchangeRateMantissa}));
    if (seizeTokenDecimal < 18) {
      denominator = denominator.mul_(10 ** (18 - seizeTokenDecimal));
    }

    ratio = numerator.div_(denominator);
    profitRatio = profitNumerator.div_(denominator);

    seizeTokens = ratio.mul_ScalarTruncate(actualRepayAmount);
    seizeProfitTokens = profitRatio.mul_ScalarTruncate(actualRepayAmount);

    return (uint256(0), seizeTokens, seizeProfitTokens);
  }

  function getAccountBorrows(address account) public view returns (uint256 principal, uint256 interestIndex) {
    BorrowSnapshot memory accountBorrow = accountBorrows[account];
    principal = accountBorrow.principal;
    interestIndex = accountBorrow.interestIndex;
  }

  function getDiscountRate() public view returns (uint256) {
    return discountRateMantissa;
  }

  function _setDiscountRate(uint256 discountRateMantissa_) external returns (uint256) {
    require(msg.sender == admin, 'UNAUTHORIZED');
    uint256 oldDiscountRateMantissa_ = discountRateMantissa;
    discountRateMantissa = discountRateMantissa_;
    emit NewDiscountRate(oldDiscountRateMantissa_, discountRateMantissa_);
    return discountRateMantissa;
  }
}
