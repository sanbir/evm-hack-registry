// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Comptroller/ComptrollerInterfaces.sol";
import "../PToken/PTokenInterfaces.sol";
import "../Utils/ExponentialNoError.sol";
import "openzeppelin2/token/ERC20/IERC20.sol";
import "../InterestRateModels/InterestRateModelInterface.sol";
import "../ErrorReporter.sol";

/**
 * @title Paribus PToken Contract
 * @notice Abstract base for PTokens
 * @author Compound, Paribus
 */
contract PToken is PTokenInterface, ExponentialNoError {
    /**
     * @notice Initialize the money market
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ EIP-20 name of this token
     * @param symbol_ EIP-20 symbol of this token
     * @param decimals_ EIP-20 decimal precision of this token
     */
    function initialize(address comptroller_,
                        InterestRateModelInterface interestRateModel_,
                        uint initialExchangeRateMantissa_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public {
        require(msg.sender == admin, "only admin may initialize the market");
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // Set initial exchange rate
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero");

        // Set the comptroller
        _setComptroller(comptroller_);

        // Initialize block number and borrow index (block number mocks depend on comptroller being set)
        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;

        // Set the interest rate model (depends on block number / borrow index)
        _setInterestRateModelFresh(interestRateModel_);

        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        protocolSeizeShareMantissa = 5e16; // default 5%;  0% == disabled

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
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (Error) {
        require(src != dst, "invalid account pair");
        require(dst != address(0), "invalid dst param");
        
        // Fail if transfer not allowed
        Error allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        // Get the allowance, infinite for the account owner
        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint(-1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        // Do the calculations, checking for {under,over}flow
        uint allowanceNew = sub_(startingAllowance, tokens, "allowance not enough");
        uint srcTokensNew = sub_(accountTokens[src], tokens, "balance not enough");
        uint dstTokensNew = add_(accountTokens[dst], tokens);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        // Eat some of the allowance (if necessary)
        if (startingAllowance != uint(-1)) {
            transferAllowances[src][spender] = allowanceNew;
        }

        // We emit a Transfer event
        emit Transfer(src, dst, tokens);

        // We call the defense hook
        comptroller.transferVerify(address(this), src, dst, tokens);

        return Error.NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint amount) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, dst, amount) == Error.NO_ERROR;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(address src, address dst, uint amount) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == Error.NO_ERROR;
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint amount) external returns (bool) {
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
    function allowance(address owner, address spender) external view returns (uint) {
        return transferAllowances[owner][spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view returns (uint) {
        return accountTokens[owner];
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev Accrues interest unless reverted
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(address owner) external returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    /**
     * @notice Get the underlying balance of the `owner` based on stored data
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`, with no interest accrued
     */
    function balanceOfUnderlyingStored(address owner) external view returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStored()});
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(address account) external view returns (uint, uint, uint) {
        return (accountTokens[account],
                borrowBalanceStoredInternal(account),
                exchangeRateStoredInternal());
    }

    /**
     * @dev Function to simply retrieve block number
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    /**
     * @notice Returns the current per-block borrow interest rate for this pToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() external view returns (uint) {
        return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    /**
     * @notice Returns the current per-block supply interest rate for this pToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() external view returns (uint) {
        return interestRateModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent() external nonReentrant returns (uint) {
        accrueInterest();
        return totalBorrows;
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(address account) external nonReentrant returns (uint) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(address account) public view returns (uint) {
        return borrowBalanceStoredInternal(account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return the calculated balance
     */
    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        // Get borrowBalance and borrowIndex
        // Note: we do not assert that the market is up to date
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        /* If borrowBalance = 0 then borrowIndex is likely also 0.
         * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
         */
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        /* Calculate new borrow balance using the interest index:
         *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
         */
        uint principalTimesIndex = mul_(borrowSnapshot.principal, borrowIndex);
        return div_(principalTimesIndex, borrowSnapshot.interestIndex);
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() public nonReentrant returns (uint) {
        accrueInterest();
        return exchangeRateStored();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the PToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view returns (uint) {
        return exchangeRateStoredInternal();
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the PToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return calculated exchange rate scaled by 1e18
     */
    function exchangeRateStoredInternal() internal view returns (uint) {
        uint _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            /*
             * If there are no tokens minted:
             *  exchangeRate = initialExchangeRate
             */
            return initialExchangeRateMantissa;
        } else {
            /*
             * Otherwise:
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint totalCash = getCashPrior();
            uint cashPlusBorrowsMinusReserves = sub_(add_(totalCash, totalBorrows), totalReserves);
            return getExp_(cashPlusBorrowsMinusReserves, _totalSupply);
        }
    }

    /// @notice Get live borrow index, including interest rates
    function getRealBorrowIndex() external view returns (uint) {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        // Short-circuit accumulating 0 interest
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return borrowIndex;
        }

        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        uint blockDelta = sub_(currentBlockNumber, accrualBlockNumberPrior);

        Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
        uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

        return borrowIndexNew;
    }

    /**
     * @notice Get cash balance of this pToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public {
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        // Short-circuit accumulating 0 interest
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return;
        }

        // Read the previous values out of storage
        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        // Calculate the current borrow interest rate
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        // Calculate the number of blocks elapsed since the last accrual
        uint blockDelta = sub_(currentBlockNumber, accrualBlockNumberPrior);

        /*
         * Calculate the interest accumulated into borrows and reserves and the new index:
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */
        Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
        uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
        uint totalBorrowsNew = add_(interestAccumulated, borrowsPrior);
        uint totalReservesNew = mul_ScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We write the previously calculated values into storage
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        // We emit an AccrueInterest event
        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
    }

    /**
     * @notice Sender supplies assets into the market and receives pTokens in exchange
     * @dev Accrues interest unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintInternal(uint mintAmount) internal nonReentrant returns (Error, uint) {
        accrueInterest();

        // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        return mintFresh(msg.sender, mintAmount);
    }

    struct MintLocalVars {
        Error err;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint totalSupplyNew;
        uint accountTokensNew;
        uint actualMintAmount;
    }

    /**
     * @notice User supplies assets into the market and receives pTokens in exchange
     * @dev Assumes interest has already been accrued up to the current block
     * @param minter The address of the account which is supplying the assets
     * @param mintAmount The amount of the underlying asset to supply
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual mint amount.
     */
    function mintFresh(address minter, uint mintAmount) internal returns (Error, uint) {
        // Fail if mint not allowed
        Error allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        if (allowed != Error.NO_ERROR) {
            return (fail(allowed), 0);
        }

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        MintLocalVars memory vars;
        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         *  We call `doTransferIn` for the minter and the mintAmount.
         *  Note: The pToken must handle variations between ERC-20 and ETH underlying.
         *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
         *  side-effects occurred. The function returns the amount actually transferred,
         *  in case of a fee. On success, the pToken holds an additional `actualMintAmount`
         *  of cash.
         */
        vars.actualMintAmount = doTransferIn(minter, mintAmount);

        /*
         * We get the current exchange rate and calculate the number of pTokens to be minted:
         *  mintTokens = actualMintAmount / exchangeRate
         */
        vars.mintTokens = div_(vars.actualMintAmount, Exp({mantissa: vars.exchangeRateMantissa}));

        /*
         * We calculate the new total supply of pTokens and minter token balance, checking for overflow:
         *  totalSupplyNew = totalSupply + mintTokens
         *  accountTokensNew = accountTokens[minter] + mintTokens
         */
        vars.totalSupplyNew = add_(totalSupply, vars.mintTokens);

        if (totalSupply == 0 && MINIMUM_LIQUIDITY > 0) {
            // first minter gets MINIMUM_LIQUIDITY pTokens less
            vars.mintTokens = sub_(vars.mintTokens, MINIMUM_LIQUIDITY, "first mint not enough");

            // permanently lock the first MINIMUM_LIQUIDITY tokens
            accountTokens[address(0)] = MINIMUM_LIQUIDITY;

            // we dont emit any Transfer, Mint events for that
        }

        vars.accountTokensNew = add_(accountTokens[minter], vars.mintTokens);

        // We write previously calculated values into storage
        totalSupply = vars.totalSupplyNew;
        accountTokens[minter] = vars.accountTokensNew;

        // We emit a Mint event and a Transfer event
        emit Mint(minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(0), minter, vars.mintTokens);

        // We call the defense hook
        comptroller.mintVerify(address(this), minter, vars.actualMintAmount, vars.mintTokens);

        return (Error.NO_ERROR, vars.actualMintAmount);
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @dev Accrues interest unless reverted
     * @param redeemTokens The number of pTokens to redeem into underlying
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemInternal(uint redeemTokens) internal nonReentrant returns (Error) {
        accrueInterest();

        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        return redeemFresh(msg.sender, redeemTokens, 0);
    }

    /**
     * @notice Sender redeems pTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest unless reverted
     * @param redeemAmount The amount of underlying to receive from redeeming pTokens
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlyingInternal(uint redeemAmount) internal nonReentrant returns (Error) {
        accrueInterest();

        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        return redeemFresh(msg.sender, 0, redeemAmount);
    }

    struct RedeemLocalVars {
        Error err;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint redeemAmount;
        uint totalSupplyNew;
        uint accountTokensNew;
    }

    /**
     * @notice User redeems pTokens in exchange for the underlying asset
     * @dev Assumes interest has already been accrued up to the current block
     * @param redeemer The address of the account which is redeeming the tokens
     * @param redeemTokensIn The number of pTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @param redeemAmountIn The number of underlying tokens to receive from redeeming pTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal returns (Error) {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        RedeemLocalVars memory vars;

        // exchangeRate = invoke Exchange Rate Stored()
        vars.exchangeRateMantissa = exchangeRateStoredInternal();

        // If redeemTokensIn > 0:
        if (redeemTokensIn > 0) {
            /*
             * We calculate the exchange rate and the amount of underlying to be redeemed:
             *  redeemTokens = redeemTokensIn
             *  redeemAmount = redeemTokensIn x exchangeRateCurrent
             */
            vars.redeemTokens = redeemTokensIn;
            vars.redeemAmount = mul_ScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), redeemTokensIn);
        } else {
            /*
             * We get the current exchange rate and calculate the amount to be redeemed:
             *  redeemTokens = redeemAmountIn / exchangeRate
             *  redeemAmount = redeemAmountIn
             */

            vars.redeemTokens = div_(redeemAmountIn, Exp({mantissa: vars.exchangeRateMantissa}));
            vars.redeemAmount = redeemAmountIn;
        }

        // Fail if redeem not allowed
        Error allowed = comptroller.redeemAllowed(address(this), redeemer, vars.redeemTokens);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        // Fail gracefully if protocol has insufficient cash
        if (getCashPrior() < vars.redeemAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH);
        }

        /*
         * We calculate the new total supply and redeemer balance, checking for underflow:
         *  totalSupplyNew = totalSupply - redeemTokens
         *  accountTokensNew = accountTokens[redeemer] - redeemTokens
         */
        vars.totalSupplyNew = sub_(totalSupply, vars.redeemTokens, "redeem too much");
        vars.accountTokensNew = sub_(accountTokens[redeemer], vars.redeemTokens, "redeem too much");

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We write previously calculated values into storage
        totalSupply = vars.totalSupplyNew;
        accountTokens[redeemer] = vars.accountTokensNew;

        /*
         * We invoke doTransferOut for the redeemer and the redeemAmount.
         *  Note: The pToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the pToken has redeemAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        doTransferOut(redeemer, vars.redeemAmount);

        // We emit a Transfer event, and a Redeem event
        emit Transfer(redeemer, address(0), vars.redeemTokens);
        emit Redeem(redeemer, vars.redeemAmount, vars.redeemTokens);

        // We call the defense hook
        comptroller.redeemVerify(address(this), redeemer, vars.redeemAmount, vars.redeemTokens);

        return Error.NO_ERROR;
    }

    /**
      * @notice Sender borrows assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrowInternal(uint borrowAmount) internal nonReentrant returns (Error) {
        accrueInterest();

        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        return borrowFresh(msg.sender, borrowAmount);
    }

    struct BorrowLocalVars {
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
    }

    /**
      * @notice Users borrow assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrowFresh(address payable borrower, uint borrowAmount) internal returns (Error) {
        // Fail if borrow not allowed
        Error allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        // Fail gracefully if protocol has insufficient underlying cash
        if (getCashPrior() < borrowAmount) {
            return fail(Error.TOKEN_INSUFFICIENT_CASH);
        }

        BorrowLocalVars memory vars;

        /*
         * We calculate the new borrower and total borrow balances, failing on overflow:
         *  accountBorrowsNew = accountBorrows + borrowAmount
         *  totalBorrowsNew = totalBorrows + borrowAmount
         */
        vars.accountBorrows = borrowBalanceStoredInternal(borrower);
        vars.accountBorrowsNew = add_(vars.accountBorrows, borrowAmount);
        vars.totalBorrowsNew = add_(totalBorrows, borrowAmount);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We write the previously calculated values into storage.
         *  Note: Avoid token reentrancy attacks by writing increased borrow before external transfer.
         */
        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        /*
         * We invoke doTransferOut for the borrower and the borrowAmount.
         *  Note: The pToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the pToken borrowAmount less of cash.
         *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
         */
        doTransferOut(borrower, borrowAmount);

        // We emit a Borrow event
        emit Borrow(borrower, borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

        // We call the defense hook
        comptroller.borrowVerify(address(this), borrower, borrowAmount);

        return Error.NO_ERROR;
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowInternal(uint repayAmount) internal nonReentrant returns (Error, uint) {
        accrueInterest();

        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        return repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowBehalfInternal(address borrower, uint repayAmount) internal nonReentrant returns (Error, uint) {
        accrueInterest();

        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        return repayBorrowFresh(msg.sender, borrower, repayAmount);
    }

    struct RepayBorrowLocalVars {
        Error err;
        uint repayAmount;
        uint borrowerIndex;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * @param payer the account paying off the borrow
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of underlying tokens being returned
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repayBorrowFresh(address payer, address borrower, uint repayAmount) internal returns (Error, uint) {
        // Fail if repayBorrow not allowed
        Error allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != Error.NO_ERROR) {
            return (fail(allowed), 0);
        }

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        RepayBorrowLocalVars memory vars;

        // We remember the original borrowerIndex for verification purposes
        vars.borrowerIndex = accountBorrows[borrower].interestIndex;

        // We fetch the amount the borrower owes, with accumulated interest
        vars.accountBorrows = borrowBalanceStoredInternal(borrower);

        // If repayAmount == -1, repayAmount = accountBorrows
        if (repayAmount == uint(-1)) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = repayAmount;
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the payer and the repayAmount
         *  Note: The pToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the pToken holds an additional repayAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *   it returns the amount actually transferred, in case of a fee.
         */
        vars.actualRepayAmount = doTransferIn(payer, vars.repayAmount);

        /*
         * We calculate the new borrower and total borrow balances, failing on underflow:
         *  accountBorrowsNew = accountBorrows - actualRepayAmount
         *  totalBorrowsNew = totalBorrows - actualRepayAmount
         */
        vars.accountBorrowsNew = sub_(vars.accountBorrows, vars.actualRepayAmount, "repay too much");
        vars.totalBorrowsNew = sub_(totalBorrows, vars.actualRepayAmount, "repay too much");

        // We write the previously calculated values into storage
        accountBorrows[borrower].principal = vars.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        // We emit a RepayBorrow event
        emit RepayBorrow(payer, borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);

        // We call the defense hook
        comptroller.repayBorrowVerify(address(this), payer, borrower, vars.actualRepayAmount, vars.borrowerIndex);

        return (Error.NO_ERROR, vars.actualRepayAmount);
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this pToken to be liquidated
     * @param pTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrowInternal(address borrower, uint repayAmount, PTokenInterface pTokenCollateral) internal nonReentrant returns (Error, uint) {
        require(pTokenCollateral.isPToken());

        accrueInterest();
        if (address(pTokenCollateral) != address(this)) {
            pTokenCollateral.accrueInterest();
        }

        // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateBorrowFresh(msg.sender, borrower, repayAmount, pTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this pToken to be liquidated
     * @param liquidator The address repaying the borrow and seizing collateral
     * @param pTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (Error, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateBorrowFresh(address liquidator, address borrower, uint repayAmount, PTokenInterface pTokenCollateral) internal returns (Error, uint) {
        require(borrower != liquidator, "invalid account pair");

        // Fail if liquidate not allowed
        Error allowed = comptroller.liquidateBorrowAllowed(address(this), address(pTokenCollateral), liquidator, borrower, repayAmount);
        if (allowed != Error.NO_ERROR) {
            return (fail(allowed), 0);
        }

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        // Verify pTokenCollateral market's block number equals current block number
        require(pTokenCollateral.accrualBlockNumber() == getBlockNumber(), "pTokenCollateral market not fresh");

        // Fail if repayAmount == -1 or 0
        require(repayAmount != uint(-1) && repayAmount > 0, "invalid argument");

        // Fail if repayBorrow fails
        (Error repayBorrowError, uint actualRepayAmount) = repayBorrowFresh(liquidator, borrower, repayAmount);
        if (repayBorrowError != Error.NO_ERROR) {
            // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
            return (repayBorrowError, 0);
        }

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We calculate the number of collateral tokens that will be seized
        uint seizeTokens = comptroller.liquidateCalculateSeizeTokens(address(this), address(pTokenCollateral), actualRepayAmount);

        // Revert if borrower collateral token balance < seizeTokens
        require(pTokenCollateral.balanceOf(borrower) >= seizeTokens, "liquidate seize too much");

        // If this is also the collateral, run seizeInternal to avoid reentrancy, otherwise make an external call
        Error seizeError;
        if (address(pTokenCollateral) == address(this)) {
            seizeError = seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            seizeError = pTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }

        // Revert if seize tokens fails (since we cannot be sure of side effects)
        require(seizeError == Error.NO_ERROR, "token seizure failed");

        // We emit a LiquidateBorrow event
        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(pTokenCollateral), seizeTokens);

        // We call the defense hook
        comptroller.liquidateBorrowVerify(address(this), address(pTokenCollateral), liquidator, borrower, actualRepayAmount, seizeTokens);

        return (Error.NO_ERROR, actualRepayAmount);
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another pToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed pToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of pTokens to seize
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(address liquidator, address borrower, uint seizeTokens) external nonReentrant returns (Error) {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    struct SeizeInternalLocalVars {
        uint borrowerTokensNew;
        uint liquidatorTokensNew;
        uint liquidatorSeizeTokens;
        uint protocolSeizeTokens;
        uint protocolSeizeAmount;
        uint exchangeRateMantissa;
        uint totalReservesNew;
        uint totalSupplyNew;
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another PToken.
     *  Its absolutely critical to use msg.sender as the seizer pToken and not a parameter.
     * @param seizerToken The contract seizing the collateral (i.e. borrowed pToken)
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of pTokens to seize
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seizeInternal(address seizerToken, address liquidator, address borrower, uint seizeTokens) internal returns (Error) {
        require(borrower != liquidator, "invalid account pair");

        // Fail if seize not allowed
        Error allowed = comptroller.seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        SeizeInternalLocalVars memory vars;

        /*
         * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
         *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
         *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
         */
        vars.borrowerTokensNew = sub_(accountTokens[borrower], seizeTokens, "seize too much");
        vars.protocolSeizeTokens = mul_(seizeTokens, Exp({mantissa: protocolSeizeShareMantissa}));
        vars.liquidatorSeizeTokens = sub_(seizeTokens, vars.protocolSeizeTokens, "seize too much");
        vars.exchangeRateMantissa = exchangeRateStoredInternal();
        vars.protocolSeizeAmount = mul_ScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), vars.protocolSeizeTokens);
        vars.totalReservesNew = add_(totalReserves, vars.protocolSeizeAmount);
        vars.totalSupplyNew = sub_(totalSupply, vars.protocolSeizeTokens, "seize too much");
        vars.liquidatorTokensNew = add_(accountTokens[liquidator], vars.liquidatorSeizeTokens);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We write the previously calculated values into storage
        totalReserves = vars.totalReservesNew;
        totalSupply = vars.totalSupplyNew;
        accountTokens[borrower] = vars.borrowerTokensNew;
        accountTokens[liquidator] = vars.liquidatorTokensNew;

        // Emit a Transfer event
        emit Transfer(borrower, liquidator, vars.liquidatorSeizeTokens);
        emit Transfer(borrower, address(this), vars.protocolSeizeTokens);
        emit ReservesAdded(address(this), vars.protocolSeizeAmount, vars.totalReservesNew);

        // We call the defense hook
        comptroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

        return Error.NO_ERROR;
    }

    /*** Admin Functions ***/

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      */
    function _setPendingAdmin(address payable newPendingAdmin) external {
        onlyAdmin();
        require(newPendingAdmin != address(0), "admin cannot be zero address");

        emit NewPendingAdmin(pendingAdmin, newPendingAdmin);
        pendingAdmin = newPendingAdmin;
    }

    /**
      * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
      * @dev Admin function for pending admin to accept role and update admin
      */
    function _acceptAdmin() external {
        require(msg.sender == pendingAdmin, "only pending admin");

        emit NewAdmin(admin, pendingAdmin);
        emit NewPendingAdmin(pendingAdmin, address(0));
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    /**
      * @notice Sets a new comptroller for the market
      * @dev Admin function to set a new comptroller
      */
    function _setComptroller(address newComptroller) public {
        onlyAdmin();
        (bool success, ) = newComptroller.staticcall(abi.encodeWithSignature("isComptroller()"));
        require(success, "not valid comptroller address");

        emit NewComptroller(address(comptroller), newComptroller);
        comptroller = ComptrollerNoNFTInterface(newComptroller);
    }

    /**
     * @notice Admin function to set the protocolSeizeShareMantissa value
     * @param newProtocolSeizeShareMantissa new protocolSeizeShareMantissa value
     */
    function _setProtocolSeizeShareMantissa(uint newProtocolSeizeShareMantissa) external {
        onlyAdmin();

        require(newProtocolSeizeShareMantissa < 1e18, "invalid argument");

        emit NewProtocolSeizeShareMantissa(protocolSeizeShareMantissa, newProtocolSeizeShareMantissa);
        protocolSeizeShareMantissa = newProtocolSeizeShareMantissa;
    }

    /**
      * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
      * @dev Admin function to accrue interest and set a new reserve factor
      */
    function _setReserveFactor(uint newReserveFactorMantissa) external nonReentrant {
        onlyAdmin();
        accrueInterest();

        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        // Check newReserveFactor ≤ maxReserveFactor
        require(newReserveFactorMantissa <= reserveFactorMaxMantissa, "invalid argument");

        emit NewReserveFactor(reserveFactorMantissa, newReserveFactorMantissa);
        reserveFactorMantissa = newReserveFactorMantissa;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring from msg.sender
     * @param addAmount Amount of addition to reserves
     */
    function _addReservesInternal(uint addAmount) internal nonReentrant {
        accrueInterest();

        // _addReservesFresh emits reserve-addition-specific logs on errors, so we don't need to.
        _addReservesFresh(addAmount);
    }

    /**
     * @notice Add reserves by transferring from caller
     * @dev Requires fresh interest accrual
     * @param addAmount Amount of addition to reserves
     * @return the actual amount added, net token fees
     */
    function _addReservesFresh(uint addAmount) internal returns (uint) {
        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        /*
         * We call doTransferIn for the caller and the addAmount
         *  Note: The pToken must handle variations between ERC-20 and ETH underlying.
         *  On success, the pToken holds an additional addAmount of cash.
         *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
         *  it returns the amount actually transferred, in case of a fee.
         */

        uint actualAddAmount = doTransferIn(msg.sender, addAmount);
        uint totalReservesNew = totalReserves + actualAddAmount;

        // Revert on overflow
        require(totalReservesNew >= totalReserves, "add reserves unexpected overflow");

        // Store reserves[n+1] = reserves[n] + actualAddAmount
        totalReserves = totalReservesNew;

        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);
        return actualAddAmount;
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     */
    function _reduceReserves(uint reduceAmount) external nonReentrant {
        onlyAdmin();
        accrueInterest();

        // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
        _reduceReservesFresh(reduceAmount);
    }

    /**
     * @notice Reduces reserves by transferring to admin
     * @dev Requires fresh interest accrual
     * @param reduceAmount Amount of reduction to reserves
     */
    function _reduceReservesFresh(uint reduceAmount) internal {
        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        // Fail if protocol has insufficient underlying cash
        require(getCashPrior() >= reduceAmount, "insufficient cash");

        // Check reduceAmount ≤ reserves[n] (totalReserves)
        require(reduceAmount <= totalReserves, "invalid argument");

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // totalReserves - reduceAmount
        uint totalReservesNew = totalReserves - reduceAmount;

        // We checked reduceAmount <= totalReserves above, so this should never revert.
        assert(totalReservesNew <= totalReserves);

        // Store reserves[n+1] = reserves[n] - reduceAmount
        totalReserves = totalReservesNew;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(admin, reduceAmount);

        emit ReservesReduced(admin, reduceAmount, totalReservesNew);
    }

    /**
     * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     */
    function _setInterestRateModel(InterestRateModelInterface newInterestRateModel) public {
        onlyAdmin();
        accrueInterest();

        // _setInterestRateModelFresh emits interest-rate-model-update-specific logs on errors, so we don't need to.
        _setInterestRateModelFresh(newInterestRateModel);
    }

    /**
     * @notice updates the interest rate model (*requires fresh interest accrual)
     * @dev Admin function to update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     */
    function _setInterestRateModelFresh(InterestRateModelInterface newInterestRateModel) internal {
        // Verify market's block number equals current block number
        require(accrualBlockNumber == getBlockNumber(), "market not fresh");

        require(newInterestRateModel.isInterestRateModel());

        emit NewMarketInterestRateModel(interestRateModel, newInterestRateModel);
        interestRateModel = newInterestRateModel;
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() internal view returns (uint);

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     */
    function doTransferIn(address from, uint amount) internal returns (uint);

    /**
     * @dev Performs a transfer out.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address payable to, uint amount) internal;

    /// @dev Prevents a contract from calling itself, directly or indirectly.
    modifier nonReentrant() {
        require(_notEntered, "reentered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /// @notice Checks caller is admin
    function onlyAdmin() internal view {
        require(msg.sender == admin, "only admin");
    }
}
