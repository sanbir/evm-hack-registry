// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./ComptrollerNoNFTPart2.sol";

/**
 * @title Paribus Comptroller Part2 Contract
 * @author Paribus
 */
contract ComptrollerNFTPart2 is ComptrollerNoNFTPart2, ComptrollerNFTCommonImpl {
    /*** Assets You Are In ***/

    function enterNFTMarkets(address[] calldata pNFTTokens) external {
        uint len = pNFTTokens.length;

        for (uint i = 0; i < len; i++) {
            addToNFTMarketInternal(PNFTToken(pNFTTokens[i]), msg.sender);
        }
    }

    function exitNFTMarket(address pNFTTokenAddress) external returns (Error) {
        PNFTToken pNFTToken = PNFTToken(pNFTTokenAddress);
        require(pNFTToken.isPNFTToken());

        // Fail if the sender is not permitted to redeem all of their tokens
        Error allowed = redeemNFTAllowedInternal(pNFTTokenAddress, msg.sender);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        Market storage marketToExit = markets[address(pNFTToken)];

        // Return true if the sender is not already ‘in’ the market
        if (!marketToExit.accountMembership[msg.sender]) {
            return Error.NO_ERROR;
        }

        // Set pToken account membership to false
        delete marketToExit.accountMembership[msg.sender];

        // Delete pToken from the account’s list of assets
        // load into memory for faster iteration
        PNFTToken[] memory userAssetList = accountNFTAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pNFTToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        PNFTToken[] storage storedList = accountNFTAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(address(pNFTToken), msg.sender);

        return Error.NO_ERROR;
    }

    function addToNFTMarketInternal(PNFTToken pNFTToken, address borrower) internal {
        require(pNFTToken.isPNFTToken());
        Market storage marketToJoin = markets[address(pNFTToken)];

        require(marketToJoin.isListed, "market not listed");

        if (marketToJoin.accountMembership[borrower]) { // already joined
            return;
        }

        marketToJoin.accountMembership[borrower] = true;
        accountNFTAssets[borrower].push(pNFTToken);

        emit MarketEntered(address(pNFTToken), borrower);
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
    * @return (standard assets collateral worth sum including collateral factor,
    *          NFT collateral worth sum including collateral factor,
    *          borrow value)
    */
    function getCollateralBorrowValues(address account) external view returns (uint, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        getHypotheticalAccountLiquidityInternalNFTImpl(account, address(0), 0, vars);

        uint nftCollateralSum = vars.sumCollateral;

        getHypotheticalAccountLiquidityInternalImpl(account, address(0), 0, 0, vars);

        return (sub_(vars.sumCollateral, nftCollateralSum), nftCollateralSum, vars.sumBorrowPlusEffects);
    }

    function nftLiquidateSendPBXBonusIncentive(uint bonusIncentive, address liquidator) external {
        require(PNFTToken(msg.sender).isPNFTToken());
        require(markets[msg.sender].isListed, "market not listed");

        grantPBXInternal(liquidator, bonusIncentive);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral pToken using stored data, without calculating accumulated interest.
     * @return (hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, uint redeemTokenId) internal view returns (uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        getHypotheticalAccountLiquidityInternalImpl(account, pTokenModify, redeemTokens, borrowAmount, vars);

        getHypotheticalAccountLiquidityInternalNFTImpl(account, pTokenModify, redeemTokenId, vars);

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (sub_(vars.sumCollateral, vars.sumBorrowPlusEffects), 0);
        } else {
            return (0, sub_(vars.sumBorrowPlusEffects, vars.sumCollateral));
        }
    }

    function getHypotheticalAccountLiquidityInternalNFTImpl(address account, address pTokenModify, uint redeemTokenId, AccountLiquidityLocalVars memory vars) internal view {
        // For each NFT asset the account is in
        uint nftAssetsLen = accountNFTAssets[account].length;

        for (uint i = 0; i < nftAssetsLen; i++) {
            PNFTToken nftAsset = accountNFTAssets[account][i];

            // Read the balances from the pToken
            vars.pTokenBalance = nftAsset.balanceOf(account);
            vars.collateralFactor = Exp({mantissa : markets[address(nftAsset)].collateralFactorMantissa});

            // For each tokenId in nftAsset
            for (uint j = 0; j < vars.pTokenBalance; j++) {
                uint tokenId = nftAsset.tokenOfOwnerByIndex(account, j);

                // Get the normalized price of the tokenId
                vars.oraclePriceMantissa = IOracleNFT(oracle).getUnderlyingNFTPrice(nftAsset, tokenId);
                require(vars.oraclePriceMantissa > 0, "price error");
                vars.oraclePrice = Exp({mantissa : vars.oraclePriceMantissa});

                // Pre-compute a conversion factor from tokens -> USD (normalized price value, 36 decimals)
                vars.tokensToDenom = mul_(mul_(vars.collateralFactor, Exp({mantissa : 1e36})), vars.oraclePrice);

                // sumCollateral += tokensToDenom
                vars.sumCollateral = add_(truncate(vars.tokensToDenom), vars.sumCollateral);

                // Calculate effects of interacting with pTokenModify tokenId
                if (redeemTokenId == tokenId && address(nftAsset) == pTokenModify) {
                    // redeem effect
                    // sumBorrowPlusEffects += tokensToDenom
                    vars.sumBorrowPlusEffects = add_(truncate(vars.tokensToDenom), vars.sumBorrowPlusEffects);
                }
            }
        }
    }

    /*** Policy Hooks, should not be marked as pure, view ***/

    function redeemNFTAllowed(address pNFTToken, address redeemer, uint tokenId) external returns (Error) {
        require(PNFTToken(pNFTToken).isPNFTToken());
        tokenId; // Shh - currently unused

        Error allowed = redeemNFTAllowedInternal(pNFTToken, redeemer);
        if (allowed != Error.NO_ERROR) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, redeemer);

        return Error.NO_ERROR;
    }

    function redeemNFTAllowedInternal(address pNFTToken, address redeemer) internal view returns (Error) {
        if (!markets[pNFTToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // If the redeemer is not 'in' the market, then we can bypass the liquidity check
        if (!markets[pNFTToken].accountMembership[redeemer]) {
            return Error.NO_ERROR;
        }

        // Otherwise, perform a hypothetical liquidity check to guard against shortfall
        // (, uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, pNFTToken, 0, 0, tokenId);
        //
        // if (shortfall > 0) {
        //     return Error.INSUFFICIENT_LIQUIDITY;
        // }

        if (hasAnyBorrow(redeemer)) {
            return Error.NONZERO_BORROW_BALANCE;
        }

        return Error.NO_ERROR;
    }

    function hasAnyBorrow(address account) internal view returns (bool) {
        // For each asset the account is in
        uint assetsLen = accountAssets[account].length;

        for (uint i = 0; i < assetsLen; i++) {
            // Read the borrow balance from the pToken
            (, uint borrowBalance, ) = accountAssets[account][i].getAccountSnapshot(account);

            if (borrowBalance > 0) {
                return true;
            }
        }

        return false;
    }

    function nftLiquidationSetUp(address pNFTToken) internal view returns (bool) {
        return (NFTXioMarketplaceZapAddress != address(0) && PNFTToken(pNFTToken).NFTXioVaultId() >= 0) ||                   // NFTXio liquidation or
               (sudoswapRouterAddress != address(0) && PNFTToken(pNFTToken).sudoswapLSSVMPairAddress() != address(0) &&      // (sudoswap liquidation and
               uniswapV3SwapRouterAddress != address(0)) ||                                                                  // uniswap) or
               (NFTCollateralSeizeLiquidationFactorMantissa > 0);                                                            // liquidator seize liquidation
    }

    function transferNFTAllowed(address pNFTToken, address src, address dst, uint tokenId) external returns (Error) {
        tokenId; // Shh - currently unused
        require(PNFTToken(pNFTToken).isPNFTToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPausedGlobal, "transfer is paused");

        // Currently the only consideration is whether or not the src is allowed to redeem this token
        Error allowed = redeemNFTAllowedInternal(pNFTToken, src);
        if (allowed != Error.NO_ERROR) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, src);
        distributeSupplierPBX(pNFTToken, dst);

        return Error.NO_ERROR;
    }

    function mintNFTAllowed(address pNFTToken, address minter, uint tokenId) external returns (Error) {
        require(PNFTToken(pNFTToken).isPNFTToken());
        require(nftLiquidationSetUp(pNFTToken), "NFT liquidation not configured");

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[pNFTToken] && !mintGuardianPausedGlobal, "mint is paused");

        minter; // Shh - currently unused

        if (!markets[pNFTToken].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (IOracleNFT(oracle).getOrRequestUnderlyingNFTPrice(PNFTToken(pNFTToken), tokenId) == 0) {
            return Error.PRICE_ERROR;
        }

        if (NFTModuleClosedBeta && !NFTModuleWhitelistedUsers[minter]) {
            return Error.NFT_USER_NOT_ALLOWED;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, minter);

        return Error.NO_ERROR;
    }

    function liquidateNFTCollateralAllowed(address pNFTTokenCollateral, address liquidator, address borrower, uint tokenId, address NFTLiquidationExchangePToken) external returns (Error) {
        require(PNFTToken(pNFTTokenCollateral).isPNFTToken());
        require(PToken(NFTLiquidationExchangePToken).isPToken());
        require(nftLiquidationSetUp(pNFTTokenCollateral), "NFT liquidation not configured");

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPausedGlobal, "seize is paused");

        tokenId; // Shh - currently unused

        if (!markets[NFTLiquidationExchangePToken].isListed || !isNFTLiquidationExchangePToken[NFTLiquidationExchangePToken]) {
            return Error.INVALID_EXCHANGE_PTOKEN;
        }

        if (!markets[pNFTTokenCollateral].isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        if (!markets[pNFTTokenCollateral].accountMembership[borrower]) {
            return Error.USER_NOT_IN_MARKET;
        }

        if (NFTModuleClosedBeta && !NFTModuleWhitelistedUsers[liquidator]) {
            return Error.NFT_USER_NOT_ALLOWED;
        }

        // First, check if borrower is liquidatable
        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, address(0), 0, 0, 0);

        if (shortfall == 0) {
            return Error.INSUFFICIENT_SHORTFALL;
        }

        // If borrower is liquidatable, we can add NFTLiquidationExchangePToken to his collateral
        addToMarketInternal(PToken(NFTLiquidationExchangePToken), borrower);

        // No revert failures beyond this point!

        /* The borrower must have shortfall in order to be liquidatable
         * Check again after adding NFTLiquidationExchangePToken to borrower's collateral
         */
        (, shortfall) = getHypotheticalAccountLiquidityInternal(borrower, address(0), 0, 0, 0);
        if (shortfall == 0) {
            return Error.INSUFFICIENT_SHORTFALL;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTTokenCollateral);
        distributeSupplierPBX(pNFTTokenCollateral, borrower);
        distributeSupplierPBX(pNFTTokenCollateral, liquidator);

        return Error.NO_ERROR;
    }
}
