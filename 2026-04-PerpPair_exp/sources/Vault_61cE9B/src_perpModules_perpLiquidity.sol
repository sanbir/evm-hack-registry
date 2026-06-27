// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./internalPerpLogic.sol";
import "../util/MatrixMath.sol";
import "../util/UtilMath.sol";
import "../manager/FeeManager.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpLiquidity is InternalPerpLogic {
    using Math for uint256;
    using SignedMath for int256;

    event LiquidityMoved(
        address indexed user,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 fee,
        bool added
    );
    
    ///@dev Adds liquidity to the pool, acting as a liquidity provider.
    ///@dev Since margin ratio of LP when adding liquidity is always 0 we require that the user has at least 10% of his total debts as collateral.
    ///@param liquidityStable Amount of stable liquidity to add into the pool
    ///@param liquidityAsset Amount of asset liquidity to add into the pool, in vAsset.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity deposit
    ///@param unverifiedReport Chainlink price report.
    function addLiquidity(uint256 liquidityStable, uint256 liquidityAsset, uint256 maxFeeValue, bytes memory unverifiedReport) public nonReentrant {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        address sender = _msgSender();
        uint256 spotPrice = getPrice();

        require(liquidityStable + (liquidityAsset * spotPrice) / oracleDecimals >= minimumLiquidityMovement, "L1"); // Error on add liquidity, under minimum movement

        // Compute fees
        uint256 fee = FeeManager.computeLiquidityDepositFee(
            liquidityStable,
            liquidityAsset,
            globalLiquidityStable,
            globalLiquidityAsset,
            spotPrice,
            oracleDecimals,
            liquidityMaxFee,
            liquidityMinFee,
            liquidityFeeK,
            decimals.liquidityFeeDecimals
        );

        if (globalLiquidityAsset == 0 && globalLiquidityStable == 0) {
            fee = 0;
        }


        uint256 feeValue =
            ((liquidityStable + (liquidityAsset * spotPrice) / oracleDecimals) * fee) / decimals.liquidityFeeDecimals;

        require(feeValue <= maxFeeValue || maxFeeValue == 0, "L2");

        _addLiquidity(liquidityStable, liquidityAsset, feeValue, spotPrice);
            
        curveParameters.lastCurveUpdate = block.timestamp;
        curveParameters.lastValidatedPrice = spotPrice;
        dy0 = 0;
        dx0 = 0;
        
        LiquidityPosition storage position = liquidityPosition[sender];
        VirtualTraderPosition storage tpos = userVirtualTraderPosition[sender];
        
        uint256 collateral = getCollateral(sender);
        (uint256 pnl, bool pnlSign) = calcPnL(sender, spotPrice);
        require(pnl<collateral || pnlSign, "C1");  //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.

        require(position.debtStable + tpos.debtStable + (position.debtAsset + tpos.debtAsset)*spotPrice/oracleDecimals <= collateral*maxLpLeverage, "L3"); //To deposit liquidity you must have collateral backing it, max leverage 10x
    }

    ///@dev Internal function to make the operations necessary for the addition of liquidity.
    ///@param liquidityStable Amount of stable liquidity to add into the pool
    ///@param liquidityAsset Amount of asset liquidity to add into the pool, in vAsset.
    ///@param feeValue Stable value of the fee associated to the liquidity deposit.
    ///@param spotPrice Oracle price of the asset.
    function _addLiquidity(
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 feeValue,
        uint256 spotPrice
    )
        private
    {
        address sender = _msgSender();
        VirtualTraderPosition storage position = userVirtualTraderPosition[sender];

        // Compute new funding rate and update it
        (uint256 newFundingRate, bool newFundingRateSign) = computeFundingRate(getPrice(), lastOperationTimestamp);
        (uint256 localFundingRate, bool localFundingRateSign) =
            UtilMath.signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);

        // Compute funding fee
        (uint256 localFundingFee, bool localFundingFeeSign) = _computeFundingFee(sender, localFundingRate, localFundingRateSign);
        (position.fundingFee, position.fundingFeeSign) =
            UtilMath.signedSum(position.fundingFee, position.fundingFeeSign, localFundingFee, localFundingFeeSign);

        LiquidityPosition storage liquidityPos = liquidityPosition[sender];
        liquidityPos.debtStable += liquidityStable;
        liquidityPos.debtAsset += liquidityAsset;
        
        // Deduct fees from deposited liquidity
        if (liquidityStable >= feeValue) {
            unchecked {
                liquidityStable -= feeValue;
            }
        } else {
            unchecked {
                liquidityPos.debtStable += feeValue - liquidityStable;
                liquidityStable = 0;
            }
        }

        // Compute fee distribution between stable and asset LPs
        _distributeLiquidityFee(feeValue, spotPrice);

        _updateFG(getPrice(), lastOperationTimestamp);

        // Remove old liquidity to re-add it
        (uint256 oldLpStableBalance, uint256 oldLpAssetBalance) = getLpLiquidityBalance(sender);
        unchecked {
            liquidityStable += oldLpStableBalance;
            liquidityAsset += oldLpAssetBalance;    
        }
        
        _updateSnapshots(sender, 0, 0);

        liquidityPos.initialStableBalance = liquidityStable;
        liquidityPos.initialAssetBalance = liquidityAsset;
        // Special case if no liquidity is present
        if (globalLiquidityAsset == 0 && globalLiquidityStable == 0) {
            liquidityPos.inverseSnapshotM = [
                [int256(1) * decimals.liquidityMDecimals, int256(0) * decimals.liquidityMDecimals],
                [int256(0) * decimals.liquidityMDecimals, int256(1) * decimals.liquidityMDecimals]
            ];
        } else {

            globalLiquidityStable -= oldLpStableBalance;
            globalLiquidityAsset -= oldLpAssetBalance;
            liquidityPos.inverseSnapshotM = MatrixMath.inverseTwoByTwo(liquidityM, decimals.liquidityMDecimals);
        }

        unchecked {
            globalLiquidityStable += liquidityStable;
            globalLiquidityAsset += liquidityAsset;
        }

        lastOperationTimestamp = block.timestamp;

        emit LiquidityMoved(
            sender,
            liquidityStable,
            liquidityAsset,
            feeValue,
            true
        );
    }

    ///@dev Removes liquidity from the pool, adding it back to the liquidity provider's balance.
    ///@param liquidityStableToRemove Amount of stable liquidity to remove from the pool
    ///@param liquidityAssetToRemove Amount of asset liquidity to remove from the pool, in vAsset.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity removal
    ///@param unverifiedReport Chainlink price report.
    function removeLiquidity(
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    )
        external
        nonReentrant
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = getPrice();

        require(
            liquidityStableToRemove + (liquidityAssetToRemove * spotPrice) / oracleDecimals >= minimumLiquidityMovement,
        "L4"
        ); // Error: Removal below min size

        address sender = _msgSender();
        _removeLiquidity(liquidityStableToRemove, liquidityAssetToRemove, sender, spotPrice, maxFeeValue);

        (uint256 pnl, bool pnlSign) = calcPnL(sender, spotPrice);
        require(pnl<getCollateral(sender) || pnlSign, "C1");  //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.
    
    }

    ///@dev Internal function to make the operations necessary for the removal of liquidity.
    ///@param liquidityStableToRemove Amount of stable liquidity to remove from the pool
    ///@param liquidityAssetToRemove Amount of asset liquidity to remove from the pool, in vAsset.
    ///@param user User to remove the liquidity for.
    ///@param spotPrice Price of the asset at the moment of liquidity removal.
    ///@param maxFeeValue Maximum value of the fee in usd the user tolerates as fee on the liquidity removal
    function _removeLiquidity(uint256 liquidityStableToRemove, uint256 liquidityAssetToRemove, address user, uint256 spotPrice, uint256 maxFeeValue) internal {
        // Get LP balances & price
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);

        // Ensure enough liquidity is available
        require(lpStableBalance >= liquidityStableToRemove && lpAssetBalance >= liquidityAssetToRemove, "L5"); // Error: Not enough liquidity

        _updateFG(spotPrice, lastOperationTimestamp); // Update funding rate

        // Compute & apply funding fee
        (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);
        VirtualTraderPosition storage position = userVirtualTraderPosition[user];
        (position.fundingFee, position.fundingFeeSign) =
            UtilMath.signedSum(position.fundingFee, position.fundingFeeSign, localFundingFee, localFundingFeeSign);

        // Snapshot new values
        _updateSnapshots(user, lpStableBalance - liquidityStableToRemove, lpAssetBalance - liquidityAssetToRemove);
        LiquidityPosition storage liqPosition = liquidityPosition[user];
        liqPosition.inverseSnapshotM = MatrixMath.inverseTwoByTwo(liquidityM, decimals.liquidityMDecimals);

        // Compute removal fee
        uint256 fee = FeeManager.computeLiquidityRemovalFee(
            liquidityStableToRemove,
            liquidityAssetToRemove,
            globalLiquidityStable,
            globalLiquidityAsset,
            spotPrice,
            oracleDecimals,
            liquidityMaxFee,
            liquidityMinFee,
            liquidityFeeK,
            decimals.liquidityFeeDecimals
        );

        // Compute fee split
        uint256 feeValue = ((liquidityStableToRemove + (liquidityAssetToRemove * spotPrice) / oracleDecimals) * fee)
            / decimals.liquidityFeeDecimals;
        require(maxFeeValue >= feeValue || maxFeeValue == 0, "L6");

        // Ensure global liquidity is sufficient
        assert(globalLiquidityStable >= liquidityStableToRemove && globalLiquidityAsset >= liquidityAssetToRemove);

        unchecked {
            globalLiquidityStable -= liquidityStableToRemove;
            globalLiquidityAsset -= liquidityAssetToRemove;
        }

        _distributeLiquidityFee(feeValue, spotPrice);

        // Deduct fee from removed liquidity
        if (liquidityStableToRemove >= feeValue) {
            unchecked {
                liquidityStableToRemove -= feeValue;
            }
        } else {
            unchecked {
                position.debtStable += feeValue - liquidityStableToRemove;
                liquidityStableToRemove = 0;
            }
        }

        // Update LP balances
        unchecked {
            //first remove LP debt, then give back stable and assets.

            (liquidityStableToRemove, liqPosition.debtStable) = UtilMath.reduceValue(liquidityStableToRemove, liqPosition.debtStable);
            (liquidityAssetToRemove, liqPosition.debtAsset) = UtilMath.reduceValue(liquidityAssetToRemove, liqPosition.debtAsset);
            
            position.balanceStable += liquidityStableToRemove;
            position.balanceAsset += liquidityAssetToRemove;
            
            if(liquidityAssetToRemove>0){
                if(totalTraderExposureSign){
                    totalTraderExposure += liquidityAssetToRemove;
                } else {
                    totalTraderExposureSign = totalTraderExposure < liquidityAssetToRemove;
                    totalTraderExposure = UtilMath.diffAbs(totalTraderExposure, liquidityAssetToRemove);
                }
            }
        }

        curveParameters.lastCurveUpdate = block.timestamp;
        curveParameters.lastValidatedPrice = spotPrice;
        dy0 = 0;
        dx0 = 0;

        lastOperationTimestamp = block.timestamp;

        emit LiquidityMoved(
            user, liquidityStableToRemove, liquidityAssetToRemove, feeValue, false
        );
    }

    ///@dev Shared logic for fee distribution between stable and asset LPs
    function _distributeLiquidityFee(uint256 feeValue, uint256 spotPrice) internal {
        uint256 totalLiquidityValue = globalLiquidityStable + (globalLiquidityAsset * spotPrice) / oracleDecimals;

        //NOTE: the fee is 0 if these conditions are not satisfied, so skipping this is irrelevant
        if (feeValue > 0 && globalLiquidityAsset != 0 && globalLiquidityStable != 0 && totalLiquidityValue > 0) {
            unchecked {
                uint256 feeStable = (feeValue * globalLiquidityStable) / totalLiquidityValue;

                // Update asset holders shares and add fee to global liquidity
                int256 aX = SafeCast.toInt256(feeStable * SafeCast.toUint256(decimals.liquidityMDecimals) / globalLiquidityStable);
                int256 aY = SafeCast.toInt256((feeValue - feeStable) * SafeCast.toUint256(decimals.liquidityMDecimals) / globalLiquidityAsset);
                liquidityM[0][0] += (aY * liquidityM[1][0] + aX * liquidityM[0][0])/ decimals.liquidityMDecimals;
                liquidityM[0][1] += (aY * liquidityM[1][1] + aX * liquidityM[0][1])/ decimals.liquidityMDecimals;
                globalLiquidityStable += feeValue;
            }
        }
    }

}
