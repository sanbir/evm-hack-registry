// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./CurveMath.sol";
import "../interfaces/IPerpPair.sol";


/**
This library holds most of the useful support functions for the PerpPair contract. To get the values of some public variables in the PerpPair contract we use static call functions, passing the address to read from.
This library short error codes are present, here is a table of these errors' descriptions.
| Error Code | Description                                               |
|------------|-----------------------------------------------------------|
| SCF        | Static call to perpPair failed                            |
 */
library UtilMath {
    using Math for uint256;
    using SignedMath for int256;
    
    /// @dev The operation failed, either due to a multiplication overflow, or a division by a zero.
    error MulDivFailed();
    
    struct ClampParameters{
        uint256 minFR;
        uint256 maxFR;
        uint256 offset;
    }

    struct TradeParams {
        address user;
        bool direction;
        uint256 size;
        uint256 addedCollateral;
        uint256 price;
        address perpPair;
    }

    struct TradeState {
        uint256 globalLiquidityStable;
        uint256 globalLiquidityAsset;
        uint256 tradeReturn;
        uint256 slippage;
        uint256 initialGuess;
        uint256 finalStableBalance;
        uint256 finalAssetBalance;
        uint256 finalStableDebt;
        uint256 finalAssetDebt;
        uint256 finalCollateral;
    }

    /// @notice Compute the absolute value of the difference between the two input numbers $z = |x-y|$.
    /// @param x x
    /// @param y y
    /// @return z $|x-y|$
    function diffAbs(uint256 x, uint256 y) public pure returns (uint256 z) {
        z = x >= y ? x - y : y - x;
    }

    /// @notice Compute the sum between two signed quantities z = x + y. Written in Yul for gas optimization purposes.
    /// @param x x
    /// @param signX sign of x
    /// @param y y
    /// @param signY sign of y
    /// @return z $x + y$
    /// @return zSign sign of z
    function signedSum(uint256 x, bool signX, uint256 y, bool signY) public pure returns (uint256 z, bool zSign) {
        if(signX==signY){
            require(x<=type(uint256).max - y, "SS1");
        }
        assembly {
            // 1 if signs match
            let sameSign := eq(signX, signY)
            
            switch sameSign
            // case 1: signs match → z = x + y, zSign = signX
            case 1 {
                z := add(x, y)
                zSign := signX
            }
            // case 0: signs differ → z = |x - y|, zSign = (x > y) == signX
            default {
                // compute zSign: if x>y then 1 else 0; compare to signX
                zSign := eq(gt(x, y), signX)

                // compute |x - y|
                // start with x - y (underflow wraps unchecked here)
                let diff := sub(x, y)
                // if x ≤ y, swap order
                if iszero(gt(x, y)) {
                    diff := sub(y, x)
                }
                z := diff
            }
        }
    }

    /// @notice Compute the sum between two signed quantities z = x + y and return z as an int256
    /// @param x x
    /// @param signX sign of x
    /// @param y y
    /// @param signY sign of y
    /// @return z $x + y$
    function signedSumToInt(uint256 x, bool signX, uint256 y, bool signY) public pure returns (int256 z) {
        bool zSign;
        if (signX == signY) {
            z = SafeCast.toInt256(x + y);
            zSign = signX;
        } else {
            zSign = (x > y) == signX;
            z = SafeCast.toInt256(diffAbs(x, y));
        }
        if (!zSign) {
            z = -z;
        }
    }


    //Compute MMR of user
    ///@notice Compute the margin ratio of a user at a given price. 
    ///@param user the user address.
    ///@param price the price of the asset.
    ///@param perpPair address of the perp contract.
    ///@param collateral user collateral
    ///@param lastOperationTimestamp timestamp of the last operation performed on perpPair.
    ///@return marginRatio Margin ratio of the user.
    function calcMR(address user, uint256 price, address perpPair, uint256 collateral, uint256 lastOperationTimestamp) public view returns (uint256 marginRatio) {
        (uint256 stableLPBalance, uint256 assetLPBalance) = getLpLiquidityBalance(perpPair, user);

        (uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,,) = getUserVirtualTraderPosition(perpPair, user);

        (, , uint256 LpDebtStable, uint256 LpDebtAsset) = IPerpPair(perpPair).liquidityPosition(user);
        
        uint256 fundingRate = getFundingRate(perpPair);
        bool fundingRateSign = getFundingRateSign(perpPair);
        if (lastOperationTimestamp != block.timestamp){
            (uint256 newFundingRate, bool newFundingRateSign) = getComputeFundingRate(perpPair, price, lastOperationTimestamp);
            (fundingRate, fundingRateSign) =
                signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);
        }
        (uint256 localFundingFee, bool localFundingFeeSign) = getComputeFundingFee(perpPair, user, fundingRate, fundingRateSign);
        (fundingFee, fundingFeeSign) = signedSum(fundingFee, fundingFeeSign, localFundingFee, localFundingFeeSign);
        
        uint256 hypoteticalMMR = calcHypotheticalMR(
            stableLPBalance + balanceStable,
            assetLPBalance + balanceAsset,
            debtStable + LpDebtStable,
            debtAsset + LpDebtAsset,
            fundingFee,
            fundingFeeSign,
            price,
            1e8,
            collateral,
            1e6,
            perpPair
        );

        return hypoteticalMMR;
    }

    //Check mmr of arbitrary position.
    ///@notice This function computes the margin ratio of an hypotetical position and compares it with the Maintanance Margin Ratio.
    ///@param balanceStable The balance in virtual stable of the position
    ///@param balanceAsset The balance in virtual asset of the position
    ///@param debtStable The debt in virtual stable of the position
    ///@param debtAsset The debt in virtual asset of the position
    ///@param fundingFee The accumulated funding fee of the position
    ///@param fundingFeeSign The accumulated funding fee sign of the position, true for positive (paying), false for negative (recieving)
    ///@param price Price of the virtual asset
    ///@param collateral Collateral covering the position in the vault
    ///@param MMRDecimals decimals of the margin ratio.
    ///@param perpPair address of the perp contract.
    ///@return marginRatio marginRatio of the hypotetical position
    function calcHypotheticalMR(
        uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,
        uint256 price,
        uint256 oracleDecimals,
        uint256 collateral,
        uint256 MMRDecimals,
        address perpPair
    )
        public
        view
        returns (uint256 marginRatio)
    {
        (uint256 pnl, bool pnlSign) = _calcPnL(
            balanceStable, balanceAsset, debtStable, debtAsset, fundingFee, fundingFeeSign, price, oracleDecimals, perpPair, true
        );

        uint256 positionValue = diffAbs(balanceAsset, debtAsset) * price / oracleDecimals;

        (uint256 totColl, bool totCollSign) = signedSum(collateral, true, pnl, pnlSign);

        //bad debt
        if (!totCollSign && totColl != 0) {
            return 0;
        }
        //position empty, any collateral is allowed
        if (positionValue == 0) {
            return MMRDecimals;
        }
        
        marginRatio = totColl * MMRDecimals
            / (positionValue);
    }

    //function to calc pnl given arbitrary balance, debt, price and fees. Useful for hipotetical pnls (checkMR)
    ///@notice This function calculates the PnL of an arbitrary position
    ///@param balanceStable stable balance of the position
    ///@param balanceAsset asset balance of the position
    ///@param debtStable stable debt of the position
    ///@param debtAsset asset debt of the position
    ///@param fundingFee funding fee gained/lost
    ///@param fundingFeeSign  sign of the funding fee, true->to pay, false->gained
    ///@param price price at which the pnl is computed
    ///@param oracleDecimals decimals of the price.
    ///@param perpPair address of the perp contract.
    ///@return pnl PnL of the position
    ///@return pnlSign sign of the PnL, false means losses
    function _calcPnL(
        uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,
        uint256 price,
        uint256 oracleDecimals,
        address perpPair,
        bool useSpotPrice
    )
        public
        view
        returns (uint256 pnl, bool pnlSign)
    {
        (uint256 diffStable, bool diffStableSign) = signedSum(balanceStable, true, debtStable, false);
        (diffStable, diffStableSign) = signedSum(diffStable, diffStableSign, fundingFee, !fundingFeeSign);
        (uint256 diffAsset, bool diffAssetSign) = signedSum(balanceAsset, true, debtAsset, false);
        (uint256 sA, uint256 sB, uint256 lA, uint256 lB) = getLongCurveParameters(perpPair);
        uint256 shortReturn;

        if (diffAsset > 1e13*oracleDecimals/price){
            if (useSpotPrice){
                shortReturn = diffAsset*price/oracleDecimals;
            }
            else if(diffAssetSign){
                shortReturn = CurveMath.computeShortReturn( diffAsset,
                                                                price, 
                                                                oracleDecimals, 
                                                                getTotalLiquidityStable(perpPair),
                                                                getTotalLiquidityStable(perpPair), 
                                                                getTotalLiquidityAsset(perpPair), 
                                                                sA, 
                                                                sB, 
                                                                1e8);
            }
            else{
                require(diffAsset <= getTotalLiquidityAsset(perpPair), "PNL1"); //Requiring more asset then in the pool to exit. Cannot exit.
                shortReturn = CurveMath.computeExactAmountInLong(diffAsset,
                                                                price, 
                                                                oracleDecimals, 
                                                                getTotalLiquidityStable(perpPair), 
                                                                getTotalLiquidityStable(perpPair), 
                                                                getTotalLiquidityAsset(perpPair), 
                                                                lA, 
                                                                lB, 
                                                                1e8);
            }
        }
        
        
        (pnl, pnlSign) = signedSum(diffStable, diffStableSign, shortReturn, diffAssetSign);
    }

    //function to calc pnl given arbitrary balance, debt, price and fees. Does not include the exiting trades losses due to slippage and fee. Useful for hipotetical pnls (checkMR)
    ///@notice This function calculates the PnL of an arbitrary position
    ///@param balanceStable stable balance of the position
    ///@param balanceAsset asset balance of the position
    ///@param debtStable stable debt of the position
    ///@param debtAsset asset debt of the position
    ///@param fundingFee funding fee gained/lost
    ///@param fundingFeeSign  sign of the funding fee, true->to pay, false->gained
    ///@param price price at which the pnl is computed
    ///@param oracleDecimals decimals of the price.
    ///@return pnl PnL of the position
    ///@return pnlSign sign of the PnL, false means losses
    function _calcPnLNoExit(
        uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,
        uint256 price,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 pnl, bool pnlSign)
    {
        (uint256 diffStable, bool diffStableSign) = signedSum(balanceStable, true, debtStable, false);
        (diffStable, diffStableSign) = signedSum(diffStable, diffStableSign, fundingFee, !fundingFeeSign);
        (uint256 diffAsset, bool diffAssetSign) = signedSum(balanceAsset, true, debtAsset, false);
        
        (pnl, pnlSign) = signedSum(diffStable, diffStableSign, diffAsset*price/oracleDecimals, diffAssetSign);
    }

    //Checks if the trade that's to be performed wuold exceed a maxSlippage
    /// @notice Checks if a trade is under a maxSlippage threshold.
    /// @param maxSlippage Slippage threshold.
    /// @param slippageDecimals decimals for slippages.
    /// @param size Size of the trade.
    /// @param spotPrice Price of the asset. 
    /// @param oracleDecimals Decimals of the price.
    /// @param tradeReturn Trade return. 
    /// @param direction direction of the trade, true for long, false for short.
    function underMaxSlippage(
        uint256 maxSlippage,
        uint256 slippageDecimals,
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 tradeReturn,
        bool direction
    )
        internal
        pure
        returns (bool)
    {
        uint256 slippage = computeSlippage(slippageDecimals, size, spotPrice, oracleDecimals, tradeReturn, direction);
        return (slippage <= maxSlippage);
    }

    /// @notice Computes the slippage of a trade.
    /// @param slippageDecimals decimals for slippages.
    /// @param size Size of the trade.
    /// @param spotPrice Price of the asset. 
    /// @param oracleDecimals Decimals of the price.
    /// @param tradeReturn Trade return. 
    /// @param direction direction of the trade, true for long, false for short.
    /// @return slippage relative slippage from oracle price.
    function computeSlippage(
        uint256 slippageDecimals,
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 tradeReturn,
        bool direction
    )
        internal
        pure
        returns (uint256 slippage)
    {
        uint256 actualPrice;
        if (direction) {
            actualPrice = size * oracleDecimals / tradeReturn;
        } else {
            actualPrice = tradeReturn * oracleDecimals / size;
        }
        slippage =
            SignedMath.abs(SafeCast.toInt256(actualPrice) - SafeCast.toInt256(spotPrice)) * slippageDecimals / spotPrice;
    }
/*
    function checkBadDebt(address user, uint256 price, address perpPair) external view {
        // Calculate PnL
        (uint256 pnl, bool pnlSign) = IPerpPair(perpPair).calcPnL(user, price);

        if(!pnlSign){
            require(pnl<IPerpPair(perpPair).getCollateral(user), "C1");  //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.
        }
    }
*/
    
    function returnTradeInfo(
        address user,
        bool direction,
        uint256 size,
        uint256 addedCollateral,
        uint256 price,
        address perpPair
    )
        external
        view
        returns (
            uint256 slippage,
            uint256 marginRatio,
            uint256 tradeReturn,
            uint256 initialGuess,
            uint256 finalStableBalance,
            uint256 finalAssetBalance,
            uint256 finalStableDebt,
            uint256 finalAssetDebt,
            uint256 finalCollateral
        )
    {
        TradeParams memory p = TradeParams(user, direction, size, addedCollateral, price, perpPair);
        TradeState memory s;

        s.globalLiquidityStable = getTotalLiquidityStable(p.perpPair);
        s.globalLiquidityAsset  = getTotalLiquidityAsset(p.perpPair);

        // ---- Curve computation ----
        {
            (
                uint256 shortA,
                uint256 shortB,
                uint256 longA,
                uint256 longB
            ) = getLongCurveParameters(p.perpPair);

            if (p.direction) {
                s.tradeReturn = CurveMath.computeLongReturn(
                    p.size,
                    p.price,
                    1e8,
                    s.globalLiquidityAsset,
                    s.globalLiquidityStable,
                    s.globalLiquidityAsset,
                    longA,
                    longB,
                    1e8
                );
            } else {
                s.tradeReturn = CurveMath.computeShortReturn(
                    p.size,
                    p.price,
                    1e8,
                    s.globalLiquidityStable,
                    s.globalLiquidityStable,
                    s.globalLiquidityAsset,
                    shortA,
                    shortB,
                    1e8
                );
            }
        }

        s.slippage = computeSlippage(1e5, p.size, p.price, 1e8, s.tradeReturn, p.direction);

        (
            uint256 balSt,
            uint256 balAs,
            uint256 debtSt,
            uint256 debtAs,
            uint256 fundingFee,
            bool fundingFeeSign,
            ,
            /* reserved */
        ) = getUserVirtualTraderPosition(p.perpPair, p.user);

        (, , uint256 lpDebtSt, uint256 lpDebtAs) = IPerpPair(p.perpPair).liquidityPosition(p.user);

        uint256 toMint;
        unchecked {
            uint256 bal = p.direction ? balSt : balAs;
            toMint = p.size > bal ? p.size - bal : 0;
        }

        s.initialGuess = p.direction
            ? s.globalLiquidityAsset - s.tradeReturn
            : s.globalLiquidityStable - s.tradeReturn;

        s.finalCollateral = getCollateral(p.perpPair, p.user) + p.addedCollateral;

        (uint256 lpBalSt, uint256 lpBalAs) = getLpLiquidityBalance(p.perpPair, p.user);

        // ---- balances/debts flat arithmetic ----
        if (p.direction) {
            s.finalAssetBalance = lpBalAs + balAs + s.tradeReturn;
            s.finalAssetDebt    = debtAs + lpDebtAs;
            s.finalStableBalance = lpBalSt + balSt - (p.size - toMint);
            s.finalStableDebt    = debtSt + lpDebtSt + toMint;
        } else {
            s.finalAssetBalance  = lpBalAs + balAs - (p.size - toMint);
            s.finalAssetDebt     = debtAs + lpDebtAs + toMint;
            s.finalStableBalance = lpBalSt + balSt + s.tradeReturn;
            s.finalStableDebt    = debtSt + lpDebtSt;
        }

        // ---- Funding fee update ----
        {
            (uint256 newRate, bool newSign) =
                getComputeFundingRate(p.perpPair, p.price, getLastOperationTimestamp(p.perpPair));

            uint256 baseRate = getFundingRate(p.perpPair);
            bool baseSign    = getFundingRateSign(p.perpPair);

            (newRate, newSign) = signedSum(baseRate, baseSign, newRate, newSign);

            (uint256 localFee, bool localFeeSign) =
                getComputeFundingFee(p.perpPair, p.user, newRate, newSign);

            // apply funding to stable balances/debts
            if (localFeeSign) {
                s.finalStableDebt    += localFee;
            } else {
                s.finalStableBalance += localFee;
            }
        }

        // ---- Margin ratio ----
        marginRatio = calcHypotheticalMR(
            s.finalStableBalance,
            s.finalAssetBalance,
            s.finalStableDebt,
            s.finalAssetDebt,
            fundingFee,
            fundingFeeSign,
            p.price,
            1e8,
            s.finalCollateral,
            1e6,
            p.perpPair
        );

        // ---- Return outputs ----
        slippage          = s.slippage;
        tradeReturn       = s.tradeReturn;
        initialGuess      = s.initialGuess;
        finalStableBalance = s.finalStableBalance;
        finalAssetBalance  = s.finalAssetBalance;
        finalStableDebt    = s.finalStableDebt;
        finalAssetDebt     = s.finalAssetDebt;
        finalCollateral    = s.finalCollateral;
    }
    

    ///@dev Clamp function. Restricts the funding rate to inside a range (minY, maxY)
    ///@param fundingRateParameter the funding rate value to clamp
    ///@param params the parameters of the clamp: max, min and offset.
    ///@param sign sign of fundingRateParameter.
    function clamp(uint256 fundingRateParameter, ClampParameters memory params, bool sign) internal pure returns(uint256, bool){
        if(fundingRateParameter > params.maxFR){
            if(sign){
                return (params.maxFR, sign);
            }
            else{
                return signedSum(params.maxFR, false, params.offset, true);
            }
            
        }
        if(fundingRateParameter < params.minFR){
            if(sign){
                return (params.minFR, sign);
            }
            else{
                return signedSum(params.minFR, false, params.offset, true);
            }
        }
        if(sign){
            return (fundingRateParameter, sign);
        }
        else{
            return signedSum(fundingRateParameter, false, params.offset, true);
        }
    }



    ///@notice Staticcall method to get the user virtual trader position from perpPair
    ///@param perpPair Address of the perpPair contract.
    ///@param user Address of the user.
    ///@return balanceStable Virtual stable balance of the user
    ///@return balanceAsset Virtual asset balance of the user
    ///@return debtStable Virtual stable debt of the user
    ///@return debtAsset Virtual asset debt of the user
    ///@return fundingFee Funding fee accumulated by the user until last update of his position.
    ///@return fundingFeeSign Funding fee sign. True for paid funding fee, false for gained.
    ///@return initialFundingRate Funding rate at the moment of the user's opening the position.
    ///@return initialFundingRateSign Funding rate sign at the moment of opening position.
    function getUserVirtualTraderPosition(address perpPair, address user)
        private
        view
        returns (
            uint256 balanceStable,
            uint256 balanceAsset,
            uint256 debtStable,
            uint256 debtAsset,
            uint256 fundingFee,
            bool fundingFeeSign,
            uint256 initialFundingRate,
            bool initialFundingRateSign
        )
    {
       return IPerpPair(perpPair).userVirtualTraderPosition(user);
    }

    ///@notice Staticcall method to get the oracle asset price from perpPair
    ///@param perpPair Address of the perpPair contract.
    ///@return price Oracle price of the asset.
    function getPrice(address perpPair)
        private
        view
        returns (uint256 price)
    {
        return IPerpPair(perpPair).getPrice();
    }    

    ///@notice Staticcall method to get the maintenance margin ratio from perpPair
    ///@param perpPair Address of the perpPair contract.
    ///@return MMR Maintenance margin ratio.
    function getMMR(address perpPair)
        private
        view
        returns (uint256 MMR)
    {
        return IPerpPair(perpPair).MMR();
    }    

    ///@notice Staticcall method to get the liquidity balance of an LP from perpPair
    ///@param perpPair Address of the perpPair contract.
    ///@param user Address of the LP.
    ///@return stableLPBalance Stable liquidity balance of the LP.
    ///@return assetLPBalance Asset liquidity balance of the LP.
    function getLpLiquidityBalance(address perpPair, address user)
        private
        view
        returns (uint256 stableLPBalance, uint256 assetLPBalance)
    {
        return IPerpPair(perpPair).getLpLiquidityBalance(user);
    }    

    ///@notice Staticcall method to get the collateral of a user from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@param user Address of the user.
    ///@return collateral Collateral of the user
    function getCollateral(address perpPair, address user) private view returns (uint256 collateral) {
        return IPerpPair(perpPair).getCollateral(user);
    }

    ///@notice Staticcall method to get the total stable liquidity in the system from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return totalStable Total stable liquidity in the system
    function getTotalLiquidityStable(address perpPair) private view returns (uint256 totalStable) {
        return IPerpPair(perpPair).globalLiquidityStable();
    }

    ///@notice Staticcall method to get the total asset liquidity in the system from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return totalAsset Total asset liquidity in the system
    function getTotalLiquidityAsset(address perpPair) private view returns (uint256 totalAsset) {
        return IPerpPair(perpPair).globalLiquidityAsset();
    }

    ///@notice Staticcall method to get the curve parameters from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return shortA Short curve parameter A.
    ///@return shortB Short curve parameter B.
    ///@return longA Long curve parameter A.
    ///@return longB Long curve parameter B.
    function getLongCurveParameters(address perpPair) private view returns (uint256 shortA, uint256 shortB, uint256 longA, uint256 longB) {
        (shortA, shortB, longA, longB, , , , ) = IPerpPair(perpPair).curveParameters();
        return (shortA, shortB, longA, longB);
    }
    
    ///@notice Staticcall method to get the accumulated funding rate from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return fundingRate accumulated funding rate.
    function getFundingRate(address perpPair) private view returns (uint256 fundingRate){
        return IPerpPair(perpPair).fundingRate();
    }

    ///@notice Staticcall method to get the accumulated funding rate sign from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return fundingRateSign accumulated funding rate sign.
    function getFundingRateSign(address perpPair) private view returns (bool fundingRateSign){
        return IPerpPair(perpPair).fundingRateSign();
    }

    ///@notice Staticcall method to get the funding fee since the last update from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@param user Address of the user.
    ///@return localFundingFee funding fee since the last update. 
    ///@return localFundingFeeSign funding fee since the last update sign. 
    function getComputeFundingFee(address perpPair, address user, uint256 newFundingRate, bool newFundingRateSign) private view returns (uint256 localFundingFee, bool localFundingFeeSign){
        return IPerpPair(perpPair)._computeFundingFee(user, newFundingRate, newFundingRateSign);
    }

    ///@dev Staticcall method to get the funding rate update since the last update from the perpPair contract.
    function getComputeFundingRate(address perpPair, uint256 price, uint256 timestamp) private view returns (uint256 localFundingRate, bool localFundingRateSign){
        return IPerpPair(perpPair).computeFundingRate(price, timestamp);
    }
    
    ///@notice Staticcall method to get the lastOperationTimestamp from the perpPair contract.
    ///@param perpPair Address of the perpPair contract.
    ///@return lastOperationTimestamp accumulated funding rate.
    function getLastOperationTimestamp(address perpPair) private view returns (uint256 lastOperationTimestamp){
        return IPerpPair(perpPair).lastOperationTimestamp();
    }

    ///@dev Computes the PnL for a user at a given oracle price.
    ///@param user target user.
    ///@param price Oracle price for the asset.
    function calcPnLNoExit(address user, uint256 price, address perpPair) public view returns (uint256, bool) {
        (uint256 balanceStable,
        uint256 balanceAsset,
        uint256 debtStable,
        uint256 debtAsset,
        uint256 fundingFee,
        bool fundingFeeSign,,) = getUserVirtualTraderPosition(perpPair, user);
        (uint256 StableLPBalance, uint256 AssetLPBalance) = getLpLiquidityBalance(perpPair, user);       
        (, , uint256 LpDebtStable, uint256 LpDebtAsset) = IPerpPair(perpPair).liquidityPosition(user);
        uint256 lastOperationTimestamp = getLastOperationTimestamp(perpPair);
        (uint256 newFundingRate, bool newFundingRateSign) = getComputeFundingRate(perpPair, price, lastOperationTimestamp);
        uint256 fundingRate = getFundingRate(perpPair);
        bool fundingRateSign = getFundingRateSign(perpPair);
        (newFundingRate, newFundingRateSign) =
            signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);
        (uint256 localFundingFee, bool localFundingFeeSign) = getComputeFundingFee(perpPair, user, newFundingRate, newFundingRateSign);
        (localFundingFee, localFundingFeeSign) = signedSum(fundingFee, fundingFeeSign, localFundingFee, localFundingFeeSign);
        return _calcPnLNoExit(
            balanceStable + StableLPBalance,
            balanceAsset + AssetLPBalance,
            debtStable + LpDebtStable,
            debtAsset + LpDebtAsset,
            localFundingFee,
            localFundingFeeSign,
            price,
            1e8
        );
    }

    function reduceValue(uint256 a, uint256 b) internal pure returns (uint256 newA, uint256 remainingB) {
        unchecked {
            if (a < b) {
                remainingB = b - a;
                newA = 0;
            } else {
                newA = a - b;
                remainingB = 0;
            }
        }
    }

    function calcSlip(uint256 p, uint256 spotP, uint256 decimals) internal pure returns (uint256 slip) {
        slip = diffAbs(p, spotP)*decimals/spotP;
    }

    function calcEMA(uint256 p, uint256 spotP, uint256 slipDecimals, uint256 oldAverage, uint256 emaParam) internal pure returns (uint256 newAverage){
        uint256 slip = calcSlip(p, spotP, slipDecimals);
        newAverage = oldAverage * emaParam/slipDecimals + slip * (slipDecimals - emaParam)/slipDecimals;
    }

    function divCeil(int256 a, int256 b) external pure returns (int256 result) {
        assembly {
            let q := sdiv(a, b)
            // 1 if remainder exists, 0 otherwise
            let hasRem := iszero(iszero(smod(a, b)))
            // 1 if signs agree (a^b >= 0), 0 otherwise
            let sameSign := iszero(slt(xor(a, b), 0))
            // add 1 only when both conditions are true
            result := add(q, and(hasRem, sameSign))
        }
    }

    //function calcMinTradeReturn(uint256 input, uint256 price, uint256 oracleDecimals, uint256 maxSlippage) public pure returns(uint256 mintradeReturn){
    //    minTradeReturn = pos.balanceAsset*price/oracleDecimals * (1e5 - maxSlippage)/1e5;
    //}

    //function computeB(uint256 deltaF, uint256 liquidityGDecimals, uint256 fundingRateDecimals) internal pure returns(int256 b){
    //    b = SafeCast.toInt256(deltaF * liquidityGDecimals / fundingRateDecimals);
    //}

}

