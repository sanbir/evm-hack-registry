// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "openzeppelin2/token/ERC20/IERC20.sol";
import "./ComptrollerCommonImpl.sol";
import "../PriceOracle/PriceOracleInterfaces.sol";

/**
 * @title Paribus Comptroller Part2 Contract with no NFT functionalities except common storage, to make no-NFT version easily upgradable to NFT one
 * @author Compound, Paribus
 */
contract ComptrollerNoNFTPart2 is ComptrollerNoNFTPart2Interface, ComptrollerNoNFTCommonImpl {
    /*** Assets You Are In ***/

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param pTokens The list of addresses of the pToken markets to be enabled
     */
    function enterMarkets(address[] calldata pTokens) external {
        uint len = pTokens.length;

        for (uint i = 0; i < len; i++) {
            addToMarketInternal(PToken(pTokens[i]), msg.sender);
        }
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset, or be providing necessary collateral for an outstanding borrow.
     * @param pTokenAddress The address of the asset to be removed
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function exitMarket(address pTokenAddress) external returns (Error) {
        PToken pToken = PToken(pTokenAddress);
        require(pToken.isPToken());

        // Get sender tokensHeld and amountOwed underlying from the pToken
        (uint tokensHeld, uint borrowBalance, ) = pToken.getAccountSnapshot(msg.sender);

        // Fail if the sender has a borrow balance
        if (borrowBalance != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE);
        }

        // Fail if the sender is not permitted to redeem all of their tokens
        Error allowed = redeemAllowedInternal(pTokenAddress, msg.sender, tokensHeld);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        Market storage marketToExit = markets[address(pToken)];

        // Return true if the sender is already not ‘in’ the market
        if (!marketToExit.accountMembership[msg.sender]) {
            return Error.NO_ERROR;
        }

        // Set pToken account membership to false
        delete marketToExit.accountMembership[msg.sender];

        // Delete pToken from the account’s list of assets
        // load into memory for faster iteration
        PToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        PToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(address(pToken), msg.sender);

        return Error.NO_ERROR;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param pToken The market to enter
     * @param borrower The address of the account to modify
     */
    function addToMarketInternal(PToken pToken, address borrower) internal {
        require(pToken.isPToken());
        Market storage marketToJoin = markets[address(pToken)];

        require(marketToJoin.isListed, "market not listed");

        if (marketToJoin.accountMembership[borrower]) { // already joined
            return;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(pToken);

        emit MarketEntered(address(pToken), borrower);
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `pTokenBalance` is the number of pTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint pTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (Error 0=success, otherwise a failure (see ErrorReporter.sol for details),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidity(account, address(0), 0, 0, 0);
    }

    /// @return (standard assets collateral worth sum including collateral factor, 0, borrow value)
    function getCollateralBorrowValues(address account) external view returns (uint, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        getHypotheticalAccountLiquidityInternalImpl(account, address(0), 0, 0, vars);

        return (vars.sumCollateral, 0, vars.sumBorrowPlusEffects);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem (if PToken)
     * @param borrowAmount The amount of underlying to hypothetically borrow (if PToken)
     * @param redeemTokenId The token ID to hypothetically redeem (if PNFTToken)
     * @return (Error 0=success, otherwise a failure (see ErrorReporter.sol for details),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, uint redeemTokenId) public view returns (Error, uint, uint) {
        (uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, pTokenModify, redeemTokens, borrowAmount, redeemTokenId);
        return (Error.NO_ERROR, liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem (if PToken)
     * @param borrowAmount The amount of underlying to hypothetically borrow (if PToken)
     * @param redeemTokenId The token ID to hypothetically redeem (if PNFTToken)
     * @dev Note that we calculate the exchangeRateStored for each collateral pToken using stored data, without calculating accumulated interest.
     * @return (hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, uint redeemTokenId) internal view returns (uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        getHypotheticalAccountLiquidityInternalImpl(account, pTokenModify, redeemTokens, borrowAmount, vars);

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (sub_(vars.sumCollateral, vars.sumBorrowPlusEffects), 0);
        } else {
            return (0, sub_(vars.sumBorrowPlusEffects, vars.sumCollateral));
        }
    }

    /// @dev returns liquidity for standard assets (by vars param)
    function getHypotheticalAccountLiquidityInternalImpl(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, AccountLiquidityLocalVars memory vars) internal view {
        // For each asset the account is in
        uint assetsLen = accountAssets[account].length;

        for (uint i = 0; i < assetsLen; i++) {
            PToken asset = accountAssets[account][i];

            // Read the balances and exchange rate from the pToken
            (vars.pTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            vars.collateralFactor = Exp({mantissa : markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa : vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = IOracle(oracle).getUnderlyingPrice(asset);
            require(vars.oraclePriceMantissa > 0, "price error");
            vars.oraclePrice = Exp({mantissa : vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> USD (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * pTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.pTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with pTokenModify
            if (address(asset) == pTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in pToken.liquidateBorrowFresh)
     * @param pTokenBorrowed The address of the borrowed pToken
     * @param pTokenCollateral The address of the collateral pToken
     * @param actualRepayAmount The amount of pTokenBorrowed underlying to convert into pTokenCollateral tokens
     * @return number of pTokenCollateral tokens to be seized in a liquidation
     */
    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint actualRepayAmount) external view returns (uint) {
        require(PToken(pTokenBorrowed).isPToken());
        require(PToken(pTokenCollateral).isPToken());

        // Read oracle prices for borrowed and collateral markets
        uint priceBorrowedMantissa = IOracle(oracle).getUnderlyingPrice(PToken(pTokenBorrowed));
        uint priceCollateralMantissa = IOracle(oracle).getUnderlyingPrice(PToken(pTokenCollateral));
        require(priceBorrowedMantissa > 0 && priceCollateralMantissa > 0, "price error");

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = PToken(pTokenCollateral).exchangeRateStored();

        // Note: reverts on error
        Exp memory numerator = mul_(Exp({mantissa : liquidationIncentiveMantissa}), Exp({mantissa : priceBorrowedMantissa}));
        Exp memory denominator = mul_(Exp({mantissa : priceCollateralMantissa}), Exp({mantissa : exchangeRateMantissa}));
        Exp memory ratio = div_(numerator, denominator);

        return mul_ScalarTruncate(ratio, actualRepayAmount);
    }

    /*** Policy Hooks, should not be marked as pure, view ***/

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     * @return 0 if the liquidateBorrow is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function liquidateBorrowAllowed(address pTokenBorrowed, address pTokenCollateral, address liquidator, address borrower, uint repayAmount) external returns (Error) {
        require(PToken(pTokenBorrowed).isPToken());

        liquidator; // Shh - currently unused

        if (!markets[pTokenBorrowed].isListed || !markets[pTokenCollateral].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // The borrower must have shortfall in order to be liquidatable
        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, address(0), 0, 0, 0);
        if (shortfall == 0) {
            return Error.INSUFFICIENT_SHORTFALL;
        }

        // The liquidator may not repay more than what is allowed by the closeFactor
        uint borrowBalance = PToken(pTokenBorrowed).borrowBalanceStored(borrower);
        uint maxClose = mul_ScalarTruncate(Exp({mantissa : closeFactorMantissa}), borrowBalance);
        if (repayAmount > maxClose) {
            return Error.TOO_MUCH_REPAY;
        }

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param pToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external returns (Error) {
        require(PToken(pToken).isPToken());

        Error allowed = redeemAllowedInternal(pToken, redeemer, redeemTokens);
        if (allowed != Error.NO_ERROR) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pToken);
        distributeSupplierPBX(pToken, redeemer);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param pToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function borrowAllowed(address pToken, address borrower, uint borrowAmount) external returns (Error) {
        require(PToken(pToken).isPToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[pToken] && !borrowGuardianPausedGlobal, "borrow is paused");

        require(borrowAmount > minBorrowAmount, "borrow amount too low");

        if (!markets[pToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (!markets[pToken].accountMembership[borrower]) {
            // only pTokens may call borrowAllowed if borrower not in market
            require(msg.sender == pToken, "sender must be pToken");

            // attempt to add borrower to the market
            addToMarketInternal(PToken(msg.sender), borrower);

            // it should be impossible to break the important invariant
            assert(markets[pToken].accountMembership[borrower]);
        }

        if (IOracle(oracle).getUnderlyingPrice(PToken(pToken)) == 0) {
            return Error.PRICE_ERROR;
        }

        uint borrowCap = borrowCaps[pToken];
        if (borrowCap != 0) { // Borrow cap of 0 corresponds to unlimited borrowing
            uint totalBorrows = PToken(pToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, pToken, 0, borrowAmount, 0);

        if (shortfall > 0) {
            return Error.INSUFFICIENT_LIQUIDITY;
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa : PToken(pToken).borrowIndex()});
        updatePBXBorrowIndex(pToken, borrowIndex);
        distributeBorrowerPBX(pToken, borrower, borrowIndex);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param pToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     * @return 0 if the transfer is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external returns (Error) {
        require(PToken(pToken).isPToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPausedGlobal, "transfer is paused");

        // Currently the only consideration is whether or not the src is allowed to redeem this many tokens
        Error allowed = redeemAllowedInternal(pToken, src, transferTokens);
        if (allowed != Error.NO_ERROR) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pToken);
        distributeSupplierPBX(pToken, src);
        distributeSupplierPBX(pToken, dst);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param pToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function mintAllowed(address pToken, address minter, uint mintAmount) external returns (Error) {
        require(PToken(pToken).isPToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[pToken] && !mintGuardianPausedGlobal, "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[pToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pToken);
        distributeSupplierPBX(pToken, minter);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param pToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(address pToken, address payer, address borrower, uint repayAmount) external returns (Error) {
        require(PToken(pToken).isPToken());

        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[pToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa : PToken(pToken).borrowIndex()});
        updatePBXBorrowIndex(pToken, borrowIndex);
        distributeBorrowerPBX(pToken, borrower, borrowIndex);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     * @return 0 if the seize is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function seizeAllowed(address pTokenCollateral, address pTokenBorrowed, address liquidator, address borrower, uint seizeTokens) external returns (Error) {
        require(PToken(pTokenCollateral).isPToken());
        require(PToken(pTokenBorrowed).isPToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPausedGlobal, "seize is paused");

        seizeTokens; // Shh - currently unused

        if (!markets[pTokenCollateral].isListed || !markets[pTokenBorrowed].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (PToken(pTokenCollateral).comptroller() != PToken(pTokenBorrowed).comptroller()) {
            return Error.COMPTROLLER_MISMATCH;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pTokenCollateral);
        distributeSupplierPBX(pTokenCollateral, borrower);
        distributeSupplierPBX(pTokenCollateral, liquidator);

        return Error.NO_ERROR;
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market. Integral part of the redeemAllowed() function.
     * @param pToken The market to verify the redeem against=
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise an error (See ErrorReporter.sol)
     */
    function redeemAllowedInternal(address pToken, address redeemer, uint redeemTokens) internal view returns (Error) {
        require(PToken(pToken).isPToken());

        if (!markets[pToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // If the redeemer is not 'in' the market, then we can bypass the liquidity check
        if (markets[pToken].accountMembership[redeemer]) {
            // Otherwise, perform a hypothetical liquidity check to guard against shortfall
            (, uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, pToken, redeemTokens, 0, 0);

            if (shortfall > 0) {
                return Error.INSUFFICIENT_LIQUIDITY;
            }
        }

        return Error.NO_ERROR;
    }

    /*** PBX Distribution ***/

    /**
    * @notice Claim all the PBX accrued by holder in all markets
    * @param holder The address to claim PBX for
    */
    function claimPBXReward(address holder) external {
        return claimPBXSingle(holder, allMarkets);
        // NFT TODO PBX reward for NFT markets?
    }

    /**
     * @notice Claim all the PBX accrued by holder in the specified markets
     * @param holder The address to claim PBX for
     * @param pTokens The list of markets to claim PBX in
     */
    function claimPBXSingle(address holder, PToken[] memory pTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimPBX(holders, pTokens, true, true);
    }

    /**
     * @notice Claim all PBX accrued by the holders
     * @param holders The addresses to claim PBX for
     * @param pTokens The list of markets to claim PBX in
     * @param borrowers Whether or not to claim PBX earned by borrowing
     * @param suppliers Whether or not to claim PBX earned by supplying
     */
    function claimPBX(address[] memory holders, PToken[] memory pTokens, bool borrowers, bool suppliers) public {
        for (uint i = 0; i < pTokens.length; i++) {
            PToken pToken = pTokens[i];
            require(markets[address(pToken)].isListed, "market must be listed");

            if (borrowers) {
                Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
                updatePBXBorrowIndex(address(pToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerPBX(address(pToken), holders[j], borrowIndex);
                }
            }

            if (suppliers) {
                updatePBXSupplyIndex(address(pToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierPBX(address(pToken), holders[j]);
                }
            }
        }

        for (uint j = 0; j < holders.length; j++) {
            PBXAccruedStored[holders[j]] = grantPBXInternal(holders[j], PBXAccruedStored[holders[j]]);
        }
    }

    /**
     * @notice The PBX accrued but not yet transferred to each user. Calculated live, for current block
     * @param holder The addresses to calculate accrued PBX for
     */
    function PBXAccrued(address holder) public view returns (uint) {
        uint result = 0;

        for (uint i = 0; i < allMarkets.length; i++) {
            PToken pToken = allMarkets[i];
            require(markets[address(pToken)].isListed, "market must be listed");

            Exp memory borrowIndex = Exp({mantissa : pToken.borrowIndex()});
            PBXMarketState memory updatedBorrowSpeed = getUpdatedPBXBorrowIndex(address(pToken), borrowIndex);
            result = add_(result, calculateTotalBorrowerPBXAccrued(address(pToken), holder, borrowIndex, updatedBorrowSpeed));

            PBXMarketState memory updatedSupplySpeed = getUpdatedPBXSupplyIndex(address(pToken));
            result = add_(result, calculateTotalSupplierPBXAccrued(address(pToken), holder, updatedSupplySpeed));
        }

        return result;
    }

    /**
     * @notice Transfer PBX to the user
     * @dev Note: If there is not enough PBX, we do not perform the transfer all.
     * @param user The address of the user to transfer PBX to
     * @param amount The amount of PBX to (possibly) transfer
     * @return The amount of PBX which was NOT transferred to the user
     */
    function grantPBXInternal(address user, uint amount) internal returns (uint) {
        IERC20 PBX = IERC20(PBXToken);
        uint PBXRemaining = PBX.balanceOf(address(this));

        if (amount > 0 && amount <= PBXRemaining) {
            require(PBX.transfer(user, amount), "transfer failed");
            return 0;
        }

        return amount;
    }

    /*** PBX Distribution Admin ***/

    /**
     * @notice Set PBX speed for a single market
     * @param pToken The market whose PBX speed to update
     * @param supplySpeed New supply-side PBX speed for market
     * @param borrowSpeed New borrow-side PBX speed for market
     */
    function setPBXSpeedInternal(PToken pToken, uint supplySpeed, uint borrowSpeed) internal {
        Market storage market = markets[address(pToken)];
        require(market.isListed, "market is not listed");

        if (PBXSupplySpeeds[address(pToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. PBX accrued properly for the old speed, and
            //  2. PBX accrued at the new speed starts after this block.
            updatePBXSupplyIndex(address(pToken));

            // Update speed and emit event
            PBXSupplySpeeds[address(pToken)] = supplySpeed;
            emit PBXSupplySpeedUpdated(pToken, supplySpeed);
        }

        if (PBXBorrowSpeeds[address(pToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. PBX accrued properly for the old speed, and
            //  2. PBX accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
            updatePBXBorrowIndex(address(pToken), borrowIndex);

            // Update speed and emit event
            PBXBorrowSpeeds[address(pToken)] = borrowSpeed;
            emit PBXBorrowSpeedUpdated(pToken, borrowSpeed);
        }
    }

    /**
     * @notice Transfer PBX to the recipient
     * @dev Note: If there is not enough PBX, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer PBX to
     * @param amount The amount of PBX to (possibly) transfer
     */
    function _grantPBX(address recipient, uint amount) external {
        adminOrInitializing();

        uint amountLeft = grantPBXInternal(recipient, amount);
        require(amountLeft == 0, "insufficient PBX for grant");
        emit PBXGranted(recipient, amount);
    }

    /**
     * @notice Set PBX borrow and supply speeds for the specified markets.
     * @param pTokens The market whose PBX speed to update
     * @param supplySpeeds New supply-side PBX speed for the corresponding market.
     * @param borrowSpeeds New borrow-side PBX speed for the corresponding market.
     */
    function _setPBXSpeeds(PToken[] calldata pTokens, uint[] calldata supplySpeeds, uint[] calldata borrowSpeeds) external {
        adminOrInitializing();

        uint numTokens = pTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid argument");

        for (uint i = 0; i < numTokens; ++i) {
            setPBXSpeedInternal(pTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Accrue PBX to the market by updating the supply index
     * @param pToken The market whose supply index to update
     * @dev Index is a cumulative sum of the PBX per pToken accrued
     */
    function updatePBXSupplyIndex(address pToken) internal {
        PBXSupplyState[pToken] = getUpdatedPBXSupplyIndex(pToken);
    }

    function getUpdatedPBXSupplyIndex(address pToken) internal view returns (PBXMarketState memory) {
        PBXMarketState memory supplyState = PBXSupplyState[pToken];

        uint supplySpeed = PBXSupplySpeeds[pToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));

        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint totalSupply = PToken(pToken).totalSupply();
            uint supplyTokens = totalSupply > 0 ? sub_(totalSupply, PToken(pToken).MINIMUM_LIQUIDITY()) : 0;
            uint newPBXAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(newPBXAccrued, supplyTokens) : Double({mantissa : 0});
            supplyState.index = safe224(add_(Double({mantissa : supplyState.index}), ratio).mantissa, "new index exceeds 224 bits");
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }

        return supplyState;
    }

    /**
     * @notice Calculate PBX accrued by a supplier and possibly transfer it to them
     * @param pToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute PBX to
     */
    function distributeSupplierPBX(address pToken, address supplier) internal {
        uint supplyIndex = PBXSupplyState[pToken].index;
        uint supplierAccrued = calculateTotalSupplierPBXAccrued(pToken, supplier, PBXSupplyState[pToken]);
        emit DistributedSupplierPBX(PToken(pToken), supplier, sub_(supplierAccrued, PBXAccruedStored[supplier]), supplyIndex);
        PBXAccruedStored[supplier] = supplierAccrued;

        // Update supplier's index to the current index since we are distributing accrued PBX
        PBXSupplierIndex[pToken][supplier] = supplyIndex;
    }

    function calculateTotalSupplierPBXAccrued(address pToken, address supplier, PBXMarketState memory supplyState) internal view returns (uint) {
        // TODO: Don't distribute supplier PBX if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierPBX is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        uint supplyIndex = supplyState.index;
        uint supplierIndex = PBXSupplierIndex[pToken][supplier];

        if (supplierIndex == 0 && supplyIndex >= PBXInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with PBX accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = PBXInitialIndex;
        }

        // Calculate change in the cumulative sum of the PBX per pToken accrued
        Double memory deltaIndex = Double({mantissa : sub_(supplyIndex, supplierIndex)});

        uint supplierTokens = PToken(pToken).balanceOf(supplier);

        // Calculate PBX accrued: pTokenAmount * accruedPerPToken
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        return add_(PBXAccruedStored[supplier], supplierDelta);
    }

    /**
     * @notice Accrue PBX to the market by updating the borrow index
     * @param pToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the PBX per pToken accrued.
     */
    function updatePBXBorrowIndex(address pToken, Exp memory marketBorrowIndex) internal {
        PBXBorrowState[pToken] = getUpdatedPBXBorrowIndex(pToken, marketBorrowIndex);
    }

    function getUpdatedPBXBorrowIndex(address pToken, Exp memory marketBorrowIndex) internal view returns (PBXMarketState memory) {
        PBXMarketState memory borrowState = PBXBorrowState[pToken];

        uint borrowSpeed = PBXBorrowSpeeds[pToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));

        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(PToken(pToken).totalBorrows(), marketBorrowIndex);
            uint newPBXAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(newPBXAccrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index = safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }

        return borrowState;
    }

    /**
    * @notice Calculate PBX accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param pToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute PBX to
     */
    function distributeBorrowerPBX(address pToken, address borrower, Exp memory marketBorrowIndex) internal {
        uint borrowIndex = PBXBorrowState[pToken].index;
        uint borrowerAccrued = calculateTotalBorrowerPBXAccrued(pToken, borrower, marketBorrowIndex, PBXBorrowState[pToken]);
        emit DistributedBorrowerPBX(PToken(pToken), borrower, sub_(borrowerAccrued, PBXAccruedStored[borrower]), borrowIndex);
        PBXAccruedStored[borrower] = borrowerAccrued;

        // Update borrower's index to the current index since we are distributing accrued PBX
        PBXBorrowerIndex[pToken][borrower] = borrowIndex;
    }

    function calculateTotalBorrowerPBXAccrued(address pToken, address borrower, Exp memory marketBorrowIndex, PBXMarketState memory borrowState) internal view returns (uint) {
        // TODO: Don't distribute supplier PBX if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerPBX is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        uint borrowIndex = borrowState.index;
        uint borrowerIndex = PBXBorrowerIndex[pToken][borrower];

        if (borrowerIndex == 0 && borrowIndex >= PBXInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with PBX accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = PBXInitialIndex;
        }

        // Calculate change in the cumulative sum of the PBX per borrowed unit accrued
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        uint borrowerAmount = div_(PToken(pToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate PBX accrued: pTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

        return add_(PBXAccruedStored[borrower], borrowerDelta);
    }
}
