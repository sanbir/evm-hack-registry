// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpAutoClose.sol";
import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpLiquidation is PerpAutoClose {
    using Math for uint256;
    using SignedMath for int256;

    event LiquidatedUser(
        address indexed user,
        address liquidator,
        uint256 fraction,
        uint256 liquidationFee,
        uint256 positionSize,
        uint256 currentPrice,
        int256 deltaPnl,
        bool liquidationDirection
    );

    //Function to liquidate users
    ///@notice This function is used to liquidate a user with an unhealthy position. A fraction of the user's position will be liquidated.
    ///@notice mgsSender is the liquidator, which will get a fraction of user's position at a discount
    ///@param user User to be liquidated.
    ///@param liquidatedPositionSize Size of the user's position to liquidate
    ///@param unverifiedReport Chainlink price report.
    function liquidate(address user, uint256 liquidatedPositionSize, bytes memory unverifiedReport) external nonReentrant {
        
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        uint256 spotPrice = getPrice();
        VirtualTraderPosition storage userPosition = userVirtualTraderPosition[user];
        VirtualTraderPosition storage liquidatorPosition = userVirtualTraderPosition[_msgSender()];

        _updateFG(spotPrice, lastOperationTimestamp);
        //Check MMR
        uint256 marginRatio = UtilMath.calcMR(user, spotPrice, address(this), getCollateral(user), lastOperationTimestamp);

        (uint256 pnlBefore, bool pnlBeforeSign) = calcPnL(user, spotPrice);

        //compute Funding Fee for user *and for liquidator(?)
        (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(_msgSender());
        (liquidatorPosition.fundingFee, liquidatorPosition.fundingFeeSign) =
        UtilMath.signedSum(
            liquidatorPosition.fundingFee,
            liquidatorPosition.fundingFeeSign,
            localFundingFee,
            localFundingFeeSign
        );
        (localFundingFee, localFundingFeeSign) = computeFundingFee(user);
        (userPosition.fundingFee, userPosition.fundingFeeSign) = UtilMath
            .signedSum(
            userPosition.fundingFee,
            userPosition.fundingFeeSign,
            localFundingFee,
            localFundingFeeSign
        );
        //update last operation timestamp
        lastOperationTimestamp = block.timestamp;

        //withdraw fraction of user LP liquidity
        (uint256 stableLiquidity, uint256 assetLiquidity) = getLpLiquidityBalance(user);
        uint256 LpDebtAsset = liquidityPosition[user].debtAsset;
   
        //check user if is liquidatable for that fraction
        uint256 fraction = liquidatedPositionSize*decimals.liquidationDecimals/UtilMath.diffAbs(assetLiquidity + userPosition.balanceAsset, userPosition.debtAsset + LpDebtAsset);
        bool expositionSide = assetLiquidity + userPosition.balanceAsset > userPosition.debtAsset + LpDebtAsset;
        if (stableLiquidity != 0 || assetLiquidity != 0) {
            _removeLiquidity(
                stableLiquidity * fraction / decimals.liquidationDecimals, assetLiquidity * fraction / decimals.liquidationDecimals, user, spotPrice, 0
            );
        }
        
        if (marginRatio <= MMR/2) {
            require(fraction <= decimals.liquidationDecimals, "LQ1"); //error on liquidate: fraction must be smaller than 1
        } else if (marginRatio <= MMR) {
            require(fraction <= decimals.liquidationDecimals/2, "LQ1"); //error on liquidate: fraction higher than 1/2 during partial liquidation
        } else {
            revert("LQ1");
        }        

        //compute d if it is dynamic
        uint256 discount = _computeLiquidationDiscount(marginRatio);
        _liquidatePosition(liquidatedPositionSize, user, discount, expositionSide);

        
        //take snapshots for _msgSender and user
        userPosition.initialFundingRate = fundingRate;
        userPosition.initialFundingRateSign = fundingRateSign;
        liquidatorPosition.initialFundingRate = fundingRate;
        liquidatorPosition.initialFundingRateSign = fundingRateSign;

        //revert if _msgSender margin ratio is not healthy
        require(UtilMath.calcMR(_msgSender(), spotPrice, address(this), getCollateral(_msgSender()), lastOperationTimestamp) > MMR, "LQ2"); //Error on Liquidation: Liquidator is not healthy

        (uint256 pnlAfter, bool pnlAfterSign) = calcPnL(user, spotPrice);
        
        int256 liquidationPnL = UtilMath.signedSumToInt(pnlBefore, !pnlBeforeSign, pnlAfter, pnlAfterSign);

        if(fraction == decimals.liquidationDecimals){
            _closeAndWithdraw(1e5, 1e10, _msgSender(), user);
            IVault(vault).removeAllCollateralForUser(user);
        }


        emit LiquidatedUser(user, _msgSender(), fraction, (liquidatedPositionSize * spotPrice/oracleDecimals) * discount / decimals.liquidationDecimals, (liquidatedPositionSize * spotPrice/oracleDecimals), spotPrice, liquidationPnL, expositionSide);
    }

    ///@dev Internal function that hangles the liquidation of a user's position.
    ///@param dAmount Size of the position that is being liquidated.
    ///@param user User owning the position to liquidate.
    ///@param discount Discount being applied to the buying of the position.
    ///@param direction Direction of the position being liquidated, true for long, false for short.
    function _liquidatePosition(uint256 dAmount, address user, uint256 discount, bool direction) private {
        address liquidator = _msgSender();
        VirtualTraderPosition storage userPosition = userVirtualTraderPosition[user];
        VirtualTraderPosition storage liquidatorPosition = userVirtualTraderPosition[liquidator];
        uint256 price = getPrice();
        if (direction) {
            //compute dy' with vamm formula for dx input
            uint256 dyPrime = CurveMath.computeShortReturn(
                dAmount,
                price,
                oracleDecimals,
                globalLiquidityStable,
                globalLiquidityStable,
                globalLiquidityAsset,
                curveParameters.shortCurveParameterA,
                curveParameters.shortCurveParameterB,
                1e8
            );
            //If slippage is over 3 times average slippage use spot price
            uint256 slip = UtilMath.calcSlip(dyPrime*oracleDecimals/dAmount, price, 1e8);
            if(slip>slipLiquidationTh*avgSlippageS){
                dyPrime = dAmount*price/oracleDecimals;
            }
            //compute dy = (1-d)dy'

            uint256 dy = (decimals.liquidationDecimals - discount) * dyPrime / decimals.liquidationDecimals;
            uint256 insuranceFraction = discount/insFundFraction*dyPrime/decimals.liquidationDecimals;
            //transfer (dy, -dx) and (-dy, dx) between user and _msgSender
            userPosition.balanceAsset -= dAmount;
            liquidatorPosition.balanceAsset += dAmount;
            if (liquidatorPosition.balanceStable >= dy) {
                liquidatorPosition.balanceStable -= dy;
            } else {
                liquidatorPosition.debtStable +=
                    dy - liquidatorPosition.balanceStable;
                liquidatorPosition.balanceStable = 0;
            }
            if (userPosition.debtStable >= dy){
                userPosition.debtStable -= dy;
            } else {
                userPosition.balanceStable += dy - userPosition.debtStable;
                userPosition.debtStable = 0;
            }
            if (liquidatorPosition.balanceStable >= insuranceFraction){
                liquidatorPosition.balanceStable -= insuranceFraction;
            } else {
                liquidatorPosition.debtStable += insuranceFraction - liquidatorPosition.balanceStable;
                liquidatorPosition.balanceStable = 0;
            }
            _assignProtocolFeeFillingInsurance(insuranceFraction, liquidator);
        } else {

            //Check if user is in bad debt, if so use spot price for liquidation
            (uint256 pnl, bool pnlSign) = calcPnL(user, price);
            uint256 dyPrime;
            if(dAmount>globalLiquidityAsset){
                dyPrime = dAmount*price/oracleDecimals;
            } else {
                //compute dy' with vamm formula for dx' output
                dyPrime = CurveMath.computeExactAmountInLong(
                    dAmount, 
                    price, 
                    oracleDecimals, 
                    globalLiquidityStable, 
                    globalLiquidityStable, 
                    globalLiquidityAsset, 
                    curveParameters.shortCurveParameterA,
                    curveParameters.shortCurveParameterB,
                    1e8
                    );
                //if slippage causes bad debt use spot price
                //Subtraction can be done safely as it is input-zeroSlippageOutput of the curve.
                (pnl, pnlSign) = UtilMath.signedSum(pnl, pnlSign, dyPrime - dAmount*price/oracleDecimals, false);
                //If slippage is over 3 times average slippage use spot price
                uint256 slip = UtilMath.calcSlip(dyPrime*oracleDecimals/dAmount, price, 1e8);
                if((pnl > getCollateral(user) && !pnlSign) || slip>slipLiquidationTh*avgSlippageL){
                    dyPrime = dAmount*price/oracleDecimals;
                }
            }
            
            
            
            //compute dy'' = (1+d)dy'
            uint256 dySecond = (decimals.liquidationDecimals + discount) * dyPrime / decimals.liquidationDecimals;
            uint256 insuranceFraction = discount/insFundFraction*dyPrime/decimals.liquidationDecimals;
            //transfer (-dAmount, dx) and (dAmount, -dx) between user and _msgSender
            if (userPosition.balanceStable >= dySecond){
                userPosition.balanceStable -= dySecond;
            } else {
                userPosition.debtStable += dySecond - userPosition.balanceStable;
                userPosition.balanceStable = 0;
            }            
            liquidatorPosition.balanceStable += dySecond;
            if (liquidatorPosition.balanceAsset >= dAmount) {
                liquidatorPosition.balanceAsset -= dAmount;
            } else {
                liquidatorPosition.debtAsset +=
                    dAmount - liquidatorPosition.balanceAsset;
                liquidatorPosition.balanceAsset = 0;
            }
            if (userPosition.debtAsset >= dAmount){
                userPosition.debtAsset -= dAmount;
            } else {
                userPosition.balanceAsset += dAmount - userPosition.debtAsset;
                userPosition.debtAsset = 0;
            }
            if (liquidatorPosition.balanceStable >= insuranceFraction){
                liquidatorPosition.balanceStable -= insuranceFraction;
            } else {
                liquidatorPosition.debtStable += insuranceFraction - liquidatorPosition.balanceStable;
                liquidatorPosition.balanceStable = 0;
            }
            _assignProtocolFeeFillingInsurance(insuranceFraction, liquidator);
        }
    }

    ///@dev Computes the liquidation discount associated to a liquidation done at a certain margin ratio.
    ///@param marginRatio Margin ratio of the user being liquidated.
    ///@return discount Discount to be applied to the liquidated position.
    function _computeLiquidationDiscount(uint256 marginRatio) private view returns (uint256 discount) {
        uint256 step1 = MMR;
        uint256 step0 = MMR/2;

        if (marginRatio <= step0) {
            unchecked {
                discount = (liquidationDiscount * (1e10 + (step0 - marginRatio) * 1e10 / step0)) / 1e10;
            }
        } else {
            unchecked {
                discount = (liquidationDiscount / 2 * (1e10 + (step1 - marginRatio) * 1e10 / (step1 - step0))) / 1e10;
            }
        }
    }

}