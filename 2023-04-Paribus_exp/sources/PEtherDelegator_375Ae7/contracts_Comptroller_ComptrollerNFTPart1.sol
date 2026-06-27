// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./ComptrollerNoNFTPart1.sol";

/**
 * @title Paribus Comptroller Part1 Contract
 * @author Compound, Paribus
 */
contract ComptrollerNFTPart1 is ComptrollerNoNFTPart1, ComptrollerNFTCommonImpl {
    /*** Assets You Are In ***/

    function getNFTAssetsIn(address account) external view returns (PNFTToken[] memory) {
        return accountNFTAssets[account];
    }

    function getAllNFTMarkets() external view returns (PNFTToken[] memory) {
        return allNFTMarkets;
    }

    function getDepositBorrowValues(address account) external view returns (uint, uint, uint) {
        (uint standardAssetsSumDeposit, uint sumBorrowPlusEffects) = getStandardAssetsDepositBorrowValuesInternal(account);
        return (standardAssetsSumDeposit, getNFTDepositValue(account), sumBorrowPlusEffects);
    }

    function getNFTDepositValue(address account) public view returns (uint) {
        uint sumDeposit = 0;

        // For every supported NFT market (no matter whether user is in (enter market) or not)
        PNFTToken[] memory nftAssets = allNFTMarkets;

        for (uint i = 0; i < nftAssets.length; i++) {
            PNFTToken nftAsset = nftAssets[i];

            // Read the balances from the pToken
            uint pTokenBalance = nftAsset.balanceOf(account);

            // For each tokenId in nftAsset
            for (uint j = 0; j < pTokenBalance; j++) {
                uint256 tokenId = nftAsset.tokenOfOwnerByIndex(account, j);

                // Get the normalized price of the tokenId
                uint oraclePriceMantissa = PriceOracleInterface(oracle).getUnderlyingNFTPrice(nftAsset, tokenId);
                require(oraclePriceMantissa > 0, "Error.PRICE_ERROR");

                // Pre-compute a conversion factor from tokens -> ether (normalized price value)
                Exp memory tokensToDenom = mul_(Exp({mantissa : oraclePriceMantissa}), Exp({mantissa : 1e36}));

                // sumDeposit += tokensToDenom
                sumDeposit = add_(truncate(tokensToDenom), sumDeposit);
            }
        }

        return sumDeposit;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /// @return (nft minimum sell value, liquidation incentive, bonus pbx incentive, liquidate seize value)
    function nftLiquidateCalculateValues(address PNFTTokenAddress, uint tokenId, address NFTLiquidationExchangePToken) external view returns (uint, uint, uint, uint) {
        require(PNFTToken(PNFTTokenAddress).isPNFTToken());
        require(markets[PNFTTokenAddress].isListed, "market not listed");

        require(NFTLiquidationExchangePToken != address(0), "invalid argument");
        require(PToken(NFTLiquidationExchangePToken).isPToken());
        require(markets[NFTLiquidationExchangePToken].isListed, "NFTLiquidationExchangePToken market not listed");
        require(isNFTLiquidationExchangePToken[NFTLiquidationExchangePToken], "NFTLiquidationExchangePToken not supported");

        // get NFT price
        Exp memory nftOraclePriceUSD = mul_(Exp({mantissa : 1e36}), Exp({mantissa : PriceOracleInterface(oracle).getUnderlyingNFTPrice(PNFTToken(PNFTTokenAddress), tokenId)})); // USD, 36 decimals
        require(truncate(nftOraclePriceUSD) > 0, "Error.PRICE_ERROR");

        // calculate nft liquidate seize price
        // can be 0 if NFTCollateralSeizeLiquidationFactorMantissa is not set!
        Exp memory nftLiquidateSeizeValueUSD = mul_(Exp({mantissa : NFTCollateralSeizeLiquidationFactorMantissa}), nftOraclePriceUSD); // USD, 36 decimals

        // calculate nft minimum sell value
        // include NFT collateral factor
        Exp memory nftTokenCollateralWorthUSD = mul_(Exp({mantissa : markets[PNFTTokenAddress].collateralFactorMantissa}), nftOraclePriceUSD); // USD, 36 decimals

        // include exchange token collateral factor
        Exp memory minSellValueUSD = div_(nftTokenCollateralWorthUSD, Exp({mantissa : markets[NFTLiquidationExchangePToken].collateralFactorMantissa})); // USD, 36 decimals

        // add 0.001 USD because of fixed-point arithmetic, so after selling NFT the account liquidity IS NEVER lower
        minSellValueUSD = add_(minSellValueUSD, Exp({mantissa : 1e33}));

        // calculate collateral liquidation incentive
        Exp memory minSellValueUSDWithIncentive = mul_(Exp({mantissa : NFTCollateralLiquidationIncentiveMantissa}), minSellValueUSD); // USD, 36 decimals

        // get NFTLiquidationExchangePToken price
        Exp memory exchangeTokenOraclePrice = Exp({mantissa : PriceOracleInterface(oracle).getUnderlyingPrice(PToken(NFTLiquidationExchangePToken))});
        require(truncate(exchangeTokenOraclePrice) > 0, "Error.PRICE_ERROR");

        {
            // convert results in USD to NFTLiquidationExchangeTokens and adjust decimals
            Exp memory minSellValue = div_(minSellValueUSD, exchangeTokenOraclePrice); // NFTLiquidationExchangeTokens
            Exp memory minSellValueWithIncentive = div_(minSellValueUSDWithIncentive, exchangeTokenOraclePrice); // NFTLiquidationExchangeTokens
            uint liquidationIncentive = truncate(sub_(minSellValueWithIncentive, minSellValue));
            uint nftLiquidateSeizeValue = truncate(div_(nftLiquidateSeizeValueUSD, exchangeTokenOraclePrice)); // NFTLiquidationExchangeTokens

            require(NFTCollateralSeizeLiquidationFactorMantissa == 0 || nftLiquidateSeizeValue >= truncate(minSellValueWithIncentive), "invalid NFTCollateralSeizeLiquidationFactorMantissa parameter, nftLiquidateSeizeValue too low");
            require(truncate(minSellValueWithIncentive) > 0, "minSellValueWithIncentive too low");

            return (truncate(minSellValueWithIncentive), liquidationIncentive, nftLiquidateCalculatePBXBonusIncentive(truncate(minSellValueUSDWithIncentive)), nftLiquidateSeizeValue);
        }
    }

    function nftLiquidateCalculatePBXBonusIncentive(uint nftMinimumSellValueUSD) public view returns (uint) {
        // calculate bonus PBX incentive
        Exp memory resultUSDWithBonusIncentive = mul_(Exp({mantissa : NFTCollateralLiquidationBonusPBXIncentiveMantissa}), Exp({mantissa : nftMinimumSellValueUSD})); // USD, 18 decimals
        Exp memory bonusIncentiveUSD = sub_(resultUSDWithBonusIncentive, Exp({mantissa : nftMinimumSellValueUSD}), 'INCENTIVE_TOO_MUCH'); // USD, 18 decimals

        // treat this as amount in PBX, adjust decimals
        uint PBXDecimals = EIP20Interface(PBXToken).decimals();
        require(PBXDecimals <= 18, "unexpected PBX token decimals");
        Exp memory bonusIncentivePBX = div_(bonusIncentiveUSD, 10 ** (18 - PBXDecimals));

        return bonusIncentivePBX.mantissa; // NFT TODO use truncate?
    }

    /*** Admin Functions ***/

    function _setNFTCollateralFactor(PNFTToken pNFTToken, uint newCollateralFactorMantissa) external returns (uint) {
        require(newCollateralFactorMantissa <= 10 ** 18, "invalid argument");
        require(pNFTToken.isPNFTToken());

        // If collateral factor != 0, fail if nft collection not supported
        if (newCollateralFactorMantissa != 0 && !PriceOracleInterface(oracle).isNFTCollectionSupported(pNFTToken.underlying())) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        return _setCollateralFactorInternal(address(pNFTToken), newCollateralFactorMantissa);
    }

    function _setNFTCollateralLiquidationIncentive(uint newNFTCollateralLiquidationIncentiveMantissa) external {
        onlyAdmin();
        require(newNFTCollateralLiquidationIncentiveMantissa >= 10 ** 18, "invalid argument");

        emit NewNFTCollateralLiquidationIncentive(NFTCollateralLiquidationIncentiveMantissa, newNFTCollateralLiquidationIncentiveMantissa);
        NFTCollateralLiquidationIncentiveMantissa = newNFTCollateralLiquidationIncentiveMantissa;
    }

    function _setNFTCollateralSeizeLiquidationFactor(uint newNFTCollateralSeizeLiquidationFactorMantissa) external {
        onlyAdmin();
        require(newNFTCollateralSeizeLiquidationFactorMantissa < 10 ** 18, "invalid argument");

        emit NewNFTCollateralSeizeLiquidationFactor(NFTCollateralSeizeLiquidationFactorMantissa, newNFTCollateralSeizeLiquidationFactorMantissa);
        NFTCollateralSeizeLiquidationFactorMantissa = newNFTCollateralSeizeLiquidationFactorMantissa;
    }

    function _setNFTCollateralLiquidationBonusPBX(uint newNFTCollateralLiquidationBonusPBXIncentiveMantissa) external {
        onlyAdmin();
        require(newNFTCollateralLiquidationBonusPBXIncentiveMantissa >= 10 ** 18, "invalid argument");

        emit NewNFTCollateralLiquidationBonusPBXIncentive(NFTCollateralLiquidationBonusPBXIncentiveMantissa, newNFTCollateralLiquidationBonusPBXIncentiveMantissa);
        NFTCollateralLiquidationBonusPBXIncentiveMantissa = newNFTCollateralLiquidationBonusPBXIncentiveMantissa;
    }

    function _supportNFTMarket(PNFTToken pNFTToken) external returns (uint) {
        require(pNFTToken.isPNFTToken());

        uint err = _supportMarketInternal(address(pNFTToken));
        if (err != uint(Error.NO_ERROR)) return err;

        for (uint i = 0; i < allNFTMarkets.length; i++) {
            require(allNFTMarkets[i] != pNFTToken, "market already added");
        }

        allNFTMarkets.push(pNFTToken);

        _initializeMarket(address(pNFTToken));
        emit MarketListed(address(pNFTToken), 1, pNFTToken.underlying());

        return uint(Error.NO_ERROR);
    }

    function _setNFTLiquidationExchangePToken(address _NFTLiquidationExchangePToken, bool enabled) external {
        onlyAdmin();
        require(PErc20Interface(_NFTLiquidationExchangePToken).isPToken());
        require(PErc20Interface(_NFTLiquidationExchangePToken).underlying() != address(0)); // sanity check
        require(markets[_NFTLiquidationExchangePToken].isListed, "NFTLiquidationExchangePToken not listed as market");

        isNFTLiquidationExchangePToken[_NFTLiquidationExchangePToken] = enabled;

        emit NFTLiquidationExchangePTokenSet(PToken(_NFTLiquidationExchangePToken), enabled);
    }

    function _setNFTXioMarketplaceZapAddress(address _NFTXioMarketplaceZapAddress) external {
        onlyAdmin();
        NFTXioMarketplaceZapAddress = _NFTXioMarketplaceZapAddress;
    }

    function _setSudoswapPairRouterAddress(address _SudoswapPairRouterAddress) external {
        onlyAdmin();
        SudoswapPairRouterAddress = _SudoswapPairRouterAddress;
    }

    function _setNFTModuleClosedBeta(bool _NFTModuleClosedBeta) external {
        onlyAdmin();
        NFTModuleClosedBeta = _NFTModuleClosedBeta;
    }

    function _NFTModuleWhitelistUser(address[] calldata whitelistedUsers) external {
        onlyAdmin();

        for (uint i = 0; i < whitelistedUsers.length; i++)
            NFTModuleWhitelistedUsers[whitelistedUsers[i]] = true;
    }

    function _NFTModuleRemoveWhitelistUser(address[] calldata removedUsers) external {
        onlyAdmin();

        for (uint i = 0; i < removedUsers.length; i++)
            NFTModuleWhitelistedUsers[removedUsers[i]] = false;
    }

    /*** Policy Hooks, should not be marked as pure, view ***/
    /*** Now empty, reserved for potential future use ***/

    function mintNFTVerify(address pNFTToken, address minter, uint tokenId) external { }

    function redeemNFTVerify(address pNFTToken, address redeemer, uint tokenId) external { }

    function transferNFTVerify(address pNFTToken, address src, address dst, uint tokenId) external { }

    function liquidateNFTCollateralVerify(address pNFTTokenCollateral, address liquidator, address borrower, uint tokenId) external { }
}
