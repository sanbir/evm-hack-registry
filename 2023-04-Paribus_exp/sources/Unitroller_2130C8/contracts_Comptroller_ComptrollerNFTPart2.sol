// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./ComptrollerNoNFTPart2.sol";

/**
 * @title Paribus Comptroller Part2 Contract
 * @author Compound, Paribus
 */
contract ComptrollerNFTPart2 is ComptrollerNoNFTPart2, ComptrollerNFTCommonImpl {
    /*** Assets You Are In ***/

    function enterNFTMarkets(address[] calldata pNFTTokens) external returns (uint[] memory) {
        uint len = pNFTTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            PNFTToken pNFTToken = PNFTToken(pNFTTokens[i]);
            results[i] = uint(addToNFTMarketInternal(pNFTToken, msg.sender));
        }

        return results;
    }

    function exitNFTMarket(address pNFTTokenAddress) external returns (uint) {
        PNFTToken pNFTToken = PNFTToken(pNFTTokenAddress);
        require(pNFTToken.isPNFTToken());

        // Fail if the sender is not permitted to redeem all of their tokens
        uint allowed = redeemNFTAllowedInternal(pNFTTokenAddress, msg.sender);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(pNFTToken)];

        // Return true if the sender is not already â€˜inâ€™ the market
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        // Set pToken account membership to false
        delete marketToExit.accountMembership[msg.sender];

        // Delete pToken from the accountâ€™s list of assets
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

        return uint(Error.NO_ERROR);
    }

    function addToNFTMarketInternal(PNFTToken pNFTToken, address borrower) internal returns (Error) {
        require(pNFTToken.isPNFTToken());
        Market storage marketToJoin = markets[address(pNFTToken)];

        if (!marketToJoin.isListed) { // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower]) { // already joined
            return Error.NO_ERROR;
        }

        marketToJoin.accountMembership[borrower] = true;
        accountNFTAssets[borrower].push(pNFTToken);

        emit MarketEntered(address(pNFTToken), borrower);
        return Error.NO_ERROR;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
    * @return (standard assets collateral worth sum including collateral factor,
    *          NFT collateral worth sum including collateral factor,
    *          borrow value)
    */
    function getCollateralBorrowValues(address account) external view returns (uint, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        Error err = getHypotheticalAccountLiquidityInternalNFTImpl(account, address(0), 0, vars);
        require(err == Error.NO_ERROR, "getHypotheticalAccountLiquidity error");

        uint nftCollateralSum = vars.sumCollateral;

        err = getHypotheticalAccountLiquidityInternalImpl(account, address(0), 0, 0, vars);
        require(err == Error.NO_ERROR, "getHypotheticalAccountLiquidity error");

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
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, uint redeemTokenId) internal view returns (uint, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results

        Error err = getHypotheticalAccountLiquidityInternalImpl(account, pTokenModify, redeemTokens, borrowAmount, vars);
        if (err != Error.NO_ERROR) return (uint(err), 0, 0);

        err = getHypotheticalAccountLiquidityInternalNFTImpl(account, pTokenModify, redeemTokenId, vars);
        if (err != Error.NO_ERROR) return (uint(err), 0, 0);

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (uint(Error.NO_ERROR), sub_(vars.sumCollateral, vars.sumBorrowPlusEffects), 0);
        } else {
            return (uint(Error.NO_ERROR), 0, sub_(vars.sumBorrowPlusEffects, vars.sumCollateral));
        }
    }

    function getHypotheticalAccountLiquidityInternalNFTImpl(address account, address pTokenModify, uint redeemTokenId, AccountLiquidityLocalVars memory vars) internal view returns (Error) {
        // For each NFT asset the account is in
        PNFTToken[] memory nftAssets = accountNFTAssets[account];

        for (uint i = 0; i < nftAssets.length; i++) {
            PNFTToken nftAsset = nftAssets[i];

            // Read the balances from the pToken
            vars.pTokenBalance = nftAsset.balanceOf(account);
            vars.collateralFactor = Exp({mantissa : markets[address(nftAsset)].collateralFactorMantissa});

            // For each tokenId in nftAsset
            for (uint j = 0; j < vars.pTokenBalance; j++) {
                uint256 tokenId = nftAsset.tokenOfOwnerByIndex(account, j);

                // Get the normalized price of the tokenId
                vars.oraclePriceMantissa = PriceOracleInterface(oracle).getUnderlyingNFTPrice(nftAsset, tokenId);
                if (vars.oraclePriceMantissa == 0) {
                    return Error.PRICE_ERROR;
                }
                vars.oraclePrice = Exp({mantissa : vars.oraclePriceMantissa});

                // Pre-compute a conversion factor from tokens -> ether (normalized price value)
                vars.tokensToDenom = mul_(mul_(vars.collateralFactor, Exp({mantissa : 1e36})), vars.oraclePrice);

                // sumCollateral += tokensToDenom
                vars.sumCollateral = add_(truncate(vars.tokensToDenom), vars.sumCollateral);

                // Calculate effects of interacting with pTokenModify tokenId
                if (redeemTokenId == tokenId && address(nftAsset) == pTokenModify) {
                    require(PNFTToken(pTokenModify).isPNFTToken());

                    // redeem effect
                    // sumBorrowPlusEffects += tokensToDenom
                    vars.sumBorrowPlusEffects = add_(truncate(vars.tokensToDenom), vars.sumBorrowPlusEffects);
                }
            }
        }

        return Error.NO_ERROR;
    }

    /*** Policy Hooks, should not be marked as pure, view ***/

    function redeemNFTAllowed(address pNFTToken, address redeemer, uint tokenId) external returns (uint) {
        tokenId; // Shh - currently unused
        require(PNFTToken(pNFTToken).isPNFTToken());

        uint allowed = redeemNFTAllowedInternal(pNFTToken, redeemer);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemNFTAllowedInternal(address pNFTToken, address redeemer) internal view returns (uint) {
        require(PNFTToken(pNFTToken).isPNFTToken());

        if (!markets[pNFTToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // If the redeemer is not 'in' the market, then we can bypass the liquidity check
        if (!markets[pNFTToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        // Otherwise, perform a hypothetical liquidity check to guard against shortfall
        // (uint err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, pNFTToken, 0, 0, tokenId);
        // if (err != uint(Error.NO_ERROR)) {
        //     return uint(err);
        // }
        // if (shortfall > 0) {
        //     return uint(Error.INSUFFICIENT_LIQUIDITY);
        // }

        if (hasAnyBorrow(redeemer)) {
            return uint(Error.NONZERO_BORROW_BALANCE);
        }

        return uint(Error.NO_ERROR);
    }

    function hasAnyBorrow(address account) internal view returns (bool) {
        // For each asset the account is in
        PToken[] memory assets = accountAssets[account];

        for (uint i = 0; i < assets.length; i++) {
            // Read the borrow balance from the pToken
            (, uint borrowBalance, ) = assets[i].getAccountSnapshot(account);

            if (borrowBalance > 0) {
                return true;
            }
        }

        return false;
    }

    function transferNFTAllowed(address pNFTToken, address src, address dst, uint tokenId) external returns (uint) {
        tokenId; // Shh - currently unused
        require(PNFTToken(pNFTToken).isPNFTToken());

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPausedGlobal, "transfer is paused");

        // Currently the only consideration is whether or not the src is allowed to redeem this token
        uint allowed = redeemNFTAllowedInternal(pNFTToken, src);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, src);
        distributeSupplierPBX(pNFTToken, dst);

        return uint(Error.NO_ERROR);
    }

    function mintNFTAllowed(address pNFTToken, address minter, uint tokenId) external returns (uint) {
        require(PNFTToken(pNFTToken).isPNFTToken());
        require((NFTXioMarketplaceZapAddress != address(0) && PNFTToken(pNFTToken).NFTXioVaultId() >= 0) ||                   // NFTXio liquidation
                (SudoswapPairRouterAddress != address(0) && PNFTToken(pNFTToken).SudoswapLSSVMPairAddress() != address(0)) || // sudoswap liquidation
                (NFTCollateralSeizeLiquidationFactorMantissa > 0), "NFT liquidation not configured");                         // liquidator seize liquidation

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[pNFTToken] && !mintGuardianPausedGlobal, "mint is paused");

        minter; // Shh - currently unused

        if (!markets[pNFTToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (PriceOracleInterface(oracle).getUnderlyingNFTPrice(PNFTToken(pNFTToken), tokenId) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        if (NFTModuleClosedBeta && !NFTModuleWhitelistedUsers[minter]) {
            return uint(Error.NFT_USER_NOT_ALLOWED);
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTToken);
        distributeSupplierPBX(pNFTToken, minter);

        return uint(Error.NO_ERROR);
    }

    function liquidateNFTCollateralAllowed(address pNFTTokenCollateral, address liquidator, address borrower, uint tokenId, address NFTLiquidationExchangePToken) external returns (uint) {
        require(PNFTToken(pNFTTokenCollateral).isPNFTToken());
        require(NFTLiquidationExchangePToken != address(0), "invalid argument");
        require(PToken(NFTLiquidationExchangePToken).isPToken());

        require((NFTXioMarketplaceZapAddress != address(0) && PNFTToken(pNFTTokenCollateral).NFTXioVaultId() >= 0) || // NFTio liquidation
                (SudoswapPairRouterAddress != address(0) && PNFTToken(pNFTTokenCollateral).SudoswapLSSVMPairAddress() != address(0)) || // sudoswap liquidation
                (NFTCollateralSeizeLiquidationFactorMantissa > 0), "NFT liquidation not configured"); // liquidator seize liquidation

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPausedGlobal, "seize is paused");

        tokenId; // Shh - currently unused

        if (!markets[NFTLiquidationExchangePToken].isListed) { // NFT TODO require?
            return uint(Error.REJECTION);
        }

        if (!isNFTLiquidationExchangePToken[NFTLiquidationExchangePToken]) {
            return uint(Error.REJECTION);
        }

        if (!markets[pNFTTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[pNFTTokenCollateral].accountMembership[borrower]) {
            return uint(Error.MARKET_NOT_ENTERED);
        }

        if (NFTModuleClosedBeta && !NFTModuleWhitelistedUsers[liquidator]) {
            return uint(Error.NFT_USER_NOT_ALLOWED);
        }

        // First, check if borrower is liquidatable
        (uint err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, address(0), 0, 0, 0);
        if (err != uint(Error.NO_ERROR)) {
            return uint(err);
        }

        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        if (PNFTToken(pNFTTokenCollateral).ownerOf(tokenId) != borrower) { // double-check that borrower is the owner of tokenId
            return uint(Error.REJECTION);
        }

        // If borrower is liquidatable, we can add NFTLiquidationExchangePToken to his collateral
        require(addToMarketInternal(PToken(NFTLiquidationExchangePToken), borrower) == Error.NO_ERROR, "sellNFTAllowed addToMarketInternal failed");

        // No revert failures beyond this point!

        /* The borrower must have shortfall in order to be liquidatable
         * Check again after adding NFTLiquidationExchangePToken to borrower's collateral
         */
        (err, , shortfall) = getHypotheticalAccountLiquidityInternal(borrower, address(0), 0, 0, 0);
        if (err != uint(Error.NO_ERROR)) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        // Keep the flywheel moving
        updatePBXSupplyIndex(pNFTTokenCollateral);
        distributeSupplierPBX(pNFTTokenCollateral, borrower);
        distributeSupplierPBX(pNFTTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }
}
