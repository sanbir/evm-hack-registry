// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpLiquidity.sol";
import "../util/UtilMath.sol";
import "../util/CurveMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";


abstract contract PerpTrade is PerpLiquidity {
    using Math for uint256;
    using SignedMath for int256;
    
    event ClosedPosition(address indexed user, uint256 pnl, bool pnlSign);

    event ExecutedTrade(
        address indexed user,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        uint256 leverage
    );

    //Function for trading asset, direction is true=long, false=short. Size is in vStable for long and vAsset for short. Initial guess is for newton method, if we compute it from frontend
    ///@dev Main trading function. Opens a trade position from the frontend. Exchange virtual stable and assets minting additional virtual tokens for the user if necessary. 
    ///@dev The separate trade positions are logged using the event being emitted in this function.
    ///@param direction Direction of the trade, true for long, false for short.
    ///@param size Size of the trade expressed in the currency to be input in the trade, vStable for long and vAsset for short.
    ///@param minTradeReturn Minimum trade return allowed for the trade by the user.
    ///@param initialGuess Initial guess for the newton method used in the curve functions to compute the trade return. 
    ///@param frontendAddress Address that collects the fees due to the frontend used for this trade. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param leverage Leverage chosen for the trade by the user. Used solely for keeping track of the trades in the events.
    ///@param unverifiedReport Chainlink price report.
    ///@return tradeReturn Currency being returned from the trade.
    function trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes memory unverifiedReport
    )
        external
        nonReentrant
        returns (uint256)
    {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        require(leverage <= maxLeverage, "T0");

        address user = _msgSender();
        uint256 spotPrice = getPrice();

        require(
            direction ? size >= minimumTradeSize : (size * spotPrice) / oracleDecimals >= minimumTradeSize,
            "T2"
        );

        uint256 tradeReturn = 
            _trade(direction, size, minTradeReturn, initialGuess, frontendAddress, user, spotPrice);


        require(
            UtilMath.calcMR(user, spotPrice, address(this), getCollateral(user), lastOperationTimestamp) > MMR,
            "T1"
        );
        

        emit ExecutedTrade(
            user,
            direction,
            size,
            tradeReturn,
            spotPrice,
            leverage
        );
        
        return tradeReturn;
    }

    ///@dev Internal trade function that handles all of the necessary operations for moving virtual assets during a trade.
    ///@param direction Direction of the trade, true for long, false for short.
    ///@param size Size of the trade expressed in the currency to be input in the trade, vStable for long and vAsset for short.
    ///@param minTradeReturn Minimum trade return allowed for the trade by the user.
    ///@param initialGuess Initial guess for the newton method used in the curve functions to compute the trade return. 
    ///@param frontendAddress Address that collects the fees due to the frontend used for this trade. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param user user which performs the trade. 
    ///@param spotPrice oracle price.
    ///@return tradeReturn Currency being returned from the trade.
    function _trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        address user,
        uint256 spotPrice
    )
        internal
        returns (uint256)
    {
        
        uint256 stableLiq = globalLiquidityStable;
        uint256 assetLiq = globalLiquidityAsset;
        uint256 tradingFeeAmount;
        uint256 tradeReturn;
        uint256 shortTotalTradeReturn;

        uint256 _oracleDecimals = oracleDecimals;
        uint256 _feeFrontend = feeFrontend;
        uint256 _lastOperationTimestamp = lastOperationTimestamp;

        uint256 zeroSlippageReturn = direction ? size * _oracleDecimals / spotPrice : size * spotPrice / _oracleDecimals;

        if(
           block.timestamp > curveParameters.lastCurveUpdate + curveParameters.curveUpdateInterval ||
           curveParameters.lastTradeDirection != direction ||
           curveParameters.lastValidatedPrice != spotPrice
           )
        {
            curveParameters.lastCurveUpdate = block.timestamp;
            curveParameters.lastTradeDirection = direction;
            curveParameters.lastValidatedPrice = spotPrice;
            delete dy0;
            delete dx0;
        }

        // Compute trade return and validate slippage
        if (direction) {
            if (assetLiq <= zeroSlippageReturn) {
                initialGuess = 0;
            }
            else if(initialGuess > assetLiq || initialGuess < (assetLiq - zeroSlippageReturn)){
                initialGuess = assetLiq - zeroSlippageReturn;
            }

            tradingFeeAmount = (size * tradingFee) / decimals.tradingFeeDecimals + flatTradingFee;
            if(size > tradingFeeAmount){
                // Only run the trade if the size is bigger than the fee. We know that we don't treat the case where the frontEnd fee is 0, but it's a minor edge case that does not affect the protocol function
                uint256 frontendFeePart = (tradingFeeAmount * _feeFrontend) / decimals.feeFractionsDecimals;
                if(frontendAddress==address(0)){
                    tradeReturn = CurveMath.computeLongReturn(
                        size - (tradingFeeAmount - frontendFeePart) + dy0,
                        spotPrice,
                        _oracleDecimals,
                        initialGuess,
                        stableLiq - dy0,
                        assetLiq + dx0,
                        curveParameters.longCurveParameterA,
                        curveParameters.longCurveParameterB,
                        1e8
                    ) - dx0;
                    dy0 += size - (tradingFeeAmount - frontendFeePart);
                }
                else{
                    tradeReturn = CurveMath.computeLongReturn(
                        size - tradingFeeAmount + dy0,
                        spotPrice,
                        _oracleDecimals,
                        initialGuess,
                        stableLiq - dy0,
                        assetLiq + dx0,
                        curveParameters.longCurveParameterA,
                        curveParameters.longCurveParameterB,
                        1e8
                    ) - dx0;
                    dy0 += size - tradingFeeAmount;
                    
                }
                if (_lastOperationTimestamp != block.timestamp){
                        avgSlippageL = UtilMath.calcEMA((size - tradingFeeAmount)*_oracleDecimals/tradeReturn, spotPrice, _oracleDecimals, avgSlippageL, emaParam);
                }
                dx0 += tradeReturn;
            } else {
                //If the trade is so small that it cannot cover its own fees then don't trade at all and only take fee.
                tradeReturn = 0;
                tradingFeeAmount = size;
            }
            


            require(tradeReturn >= minTradeReturn && tradeReturn <= zeroSlippageReturn, "T4");

        } else {
            if (stableLiq <= zeroSlippageReturn) {
                initialGuess = 0;
            }
            else if(initialGuess > stableLiq || initialGuess < (stableLiq - zeroSlippageReturn)){
                initialGuess = stableLiq - (size * spotPrice) / _oracleDecimals;
            }

            shortTotalTradeReturn = CurveMath.computeShortReturn(
                size + dx0,
                spotPrice,
                _oracleDecimals,
                initialGuess + dy0,
                stableLiq + dy0,
                assetLiq - dx0,
                curveParameters.shortCurveParameterA,
                curveParameters.shortCurveParameterB,
                1e8
            ) - dy0;
            if (_lastOperationTimestamp != block.timestamp){
                avgSlippageS = UtilMath.calcEMA(shortTotalTradeReturn*_oracleDecimals/size, spotPrice, _oracleDecimals, avgSlippageS, emaParam);
            }
            //Might miss LP fees, but even if it does the effect of this is minimal (impact of fees on liquidity and thus slippage should be minimal, and here we're not doing accounting)
            dx0 += size;
            dy0 += shortTotalTradeReturn;
            
            tradingFeeAmount = (shortTotalTradeReturn * tradingFee) / decimals.tradingFeeDecimals + flatTradingFee;
            if(tradingFeeAmount < shortTotalTradeReturn){
                tradeReturn = shortTotalTradeReturn - tradingFeeAmount;
            } else {
                tradingFeeAmount = shortTotalTradeReturn;
                tradeReturn = 0;
            }
            
            if(frontendAddress==address(0)){
                tradeReturn += (tradingFeeAmount * _feeFrontend) / decimals.feeFractionsDecimals;
            }

            require(tradeReturn >= minTradeReturn && tradeReturn <= zeroSlippageReturn,"T4");
        }

        require(direction ? tradeReturn < assetLiq : tradeReturn < stableLiq, "T5");

        _updateFG(spotPrice, _lastOperationTimestamp); // Update Funding Rate and G vector

        unchecked {
            VirtualTraderPosition storage userPosition = userVirtualTraderPosition[user];

            (uint256 localFundingFee, bool localFundingFeeSign) = computeFundingFee(user);

            // Update cumulative funding fee for trader and make new snapshots
            (userPosition.fundingFee, userPosition.fundingFeeSign) =
                UtilMath.signedSum(userPosition.fundingFee, userPosition.fundingFeeSign, localFundingFee, localFundingFeeSign);

            // Store new snapshots
            userPosition.initialFundingRate = fundingRate;
            userPosition.initialFundingRateSign = fundingRateSign;
            liquidityPosition[user].snapshotG = matrixRowG;

            if (direction) {
                (totalTraderExposure, totalTraderExposureSign) =
                    UtilMath.signedSum(totalTraderExposure, totalTraderExposureSign, tradeReturn, true);
                userPosition.balanceAsset += tradeReturn;
                if(size<=userPosition.balanceStable){
                    userPosition.balanceStable -= size;
                }
                else{
                    userPosition.debtStable += size - userPosition.balanceStable;
                    userPosition.balanceStable = 0;
                }
            } else {
                (totalTraderExposure, totalTraderExposureSign) =
                    UtilMath.signedSum(totalTraderExposure, totalTraderExposureSign, size, false);
                userPosition.balanceStable += tradeReturn;
                if(size<=userPosition.balanceAsset){
                    userPosition.balanceAsset -= size;
                }
                else{
                    userPosition.debtAsset += size - userPosition.balanceAsset;
                    userPosition.balanceAsset = 0;
                }
            }
            lastOperationTimestamp = block.timestamp;
        }

        int256 aY;
        int256 aX;

        uint256 feeFracDec = decimals.feeFractionsDecimals;
        int256 liqMDec = decimals.liquidityMDecimals;
        uint256 liqMDecU = SafeCast.toUint256(liqMDec);

        uint256 feeLPShare = (tradingFeeAmount * feeLP) / feeFracDec;

        if (direction) {
            unchecked {
                uint256 adjSize = size - tradingFeeAmount * (feeFracDec - feeLP) / feeFracDec;
                if (frontendAddress == address(0)) {
                    adjSize += (tradingFeeAmount * _feeFrontend) / feeFracDec;
                }

                aY = SafeCast.toInt256(adjSize * liqMDecU / assetLiq);
                aX = SafeCast.toInt256(tradeReturn * liqMDecU / assetLiq);

                int256 m10 = liquidityM[1][0];
                int256 m11 = liquidityM[1][1];

                liquidityM[0][0] += aY * m10 / liqMDec;
                liquidityM[0][1] += aY * m11 / liqMDec;
                liquidityM[1][0] = m10 - UtilMath.divCeil(aX * m10, liqMDec);
                liquidityM[1][1] = m11 - UtilMath.divCeil(aX * m11, liqMDec);

                globalLiquidityStable += adjSize;
                globalLiquidityAsset -= tradeReturn;
            }
        } else {
            unchecked {
                uint256 netReturn = shortTotalTradeReturn - feeLPShare;

                aX = SafeCast.toInt256(size * liqMDecU / stableLiq);
                aY = SafeCast.toInt256(netReturn * liqMDecU / stableLiq);

                int256 m00 = liquidityM[0][0];
                int256 m01 = liquidityM[0][1];

                liquidityM[1][0] += aX * m00 / liqMDec;
                liquidityM[1][1] += aX * m01 / liqMDec;
                liquidityM[0][0] = m00 - UtilMath.divCeil(aY * m00, liqMDec);
                liquidityM[0][1] = m01 - UtilMath.divCeil(aY * m01, liqMDec);

                globalLiquidityStable -= netReturn;
                globalLiquidityAsset += size;
            }
        }
        unchecked {
            _assignProtocolFeeFillingInsurance((tradingFeeAmount * (feeFracDec - feeLP - _feeFrontend)) / feeFracDec, feeProtocolAddr);
            if (frontendAddress != address(0)){
                userVirtualTraderPosition[frontendAddress].balanceStable += (tradingFeeAmount * _feeFrontend) / feeFracDec;
            }
        }
        
        require(globalLiquidityStable >= 1e18 && globalLiquidityAsset * spotPrice / oracleDecimals >= 1e18, "T3");
    
        return tradeReturn;
    }


    ///@dev Function to assing the a fee to protocolAddr passed as input only if the insuranceFund is full, otherwise it fills it first.
    ///@param fee The fee to be assigned.
    ///@param protocolAddr Address that holds the fees.
    function _assignProtocolFeeFillingInsurance(uint256 fee, address protocolAddr) internal {
        if (insuranceFundSign) {
            uint256 current = insuranceFund;
            // If under cap, fill insurance fund first
            if (current < insuranceFundCap) {
                uint256 capLeft = insuranceFundCap - current;
                if (fee <= capLeft) {
                    // Fully absorb fee
                    insuranceFund = current + fee;
                    return;
                }
                // Partially fill and forward remainder
                insuranceFund = insuranceFundCap;
                userVirtualTraderPosition[protocolAddr].balanceStable += fee - capLeft;
                return;
            }
            // Already at cap: forward entire fee
            userVirtualTraderPosition[protocolAddr].balanceStable += fee;
            return;
        }

        // insuranceFundSign == false: signed addition mode
        uint256 signedCapacity = insuranceFundCap + insuranceFund;
        if (fee <= signedCapacity) {
            // Fits within signed capacity
            (insuranceFund, insuranceFundSign) = UtilMath.signedSum(
                insuranceFund,
                insuranceFundSign,
                fee,
                true
            );
            return;
        }
        
        // Exceeds cap: fill to cap and forward remainder
        userVirtualTraderPosition[protocolAddr].balanceStable += fee - signedCapacity;
        insuranceFund = insuranceFundCap;
        insuranceFundSign = true;
    }

    ///@dev Closes the virtual position of the user and adds (or subtracts) the pnl to the user's collateral in the vault.
    ///@param maxSlippage Maximum slippage allowed for the trade by the user.
    ///@param maxLiqFee Maximum liquidity fee allowd for the liquidity removal by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param unverifiedReport Chainlink price report.
    function closeAndWithdraw(uint256 maxSlippage, uint256 maxLiqFee, address frontendAddress, bytes memory unverifiedReport) public nonReentrant {
        address user = _msgSender();
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        _closeAndWithdraw(maxSlippage, maxLiqFee, frontendAddress, user);   
    }

    //Function to be called when exiting the system. It repays all debts (if possible) and returns final pnl
    ///@dev Internal function that handles the closing of a position.
    ///@param maxSlippage Maximum slippage allowed for the trade by the user.
    ///@param maxLiqFee Maximum liquidity fee allowd for the liquidity removal by the user.
    ///@param frontendAddress Address that collects the fees due to the frontend used for this operation. Giving address(0) as frontendAddress will skip assigning the fees to a frontend.
    ///@param user User owning the position to close
    function _closeAndWithdraw(uint256 maxSlippage, uint256 maxLiqFee, address frontendAddress, address user) internal {
        uint256 price = getPrice();
        (uint256 lpStableBalance, uint256 lpAssetBalance) = getLpLiquidityBalance(user);
        VirtualTraderPosition storage pos = userVirtualTraderPosition[user];

        // Close liquidity positions if needed
        if ((lpStableBalance | lpAssetBalance | liquidityPosition[user].debtAsset | liquidityPosition[user].debtStable)!=0) {
            _removeLiquidity(lpStableBalance, lpAssetBalance, user, price, maxLiqFee);
            uint256 assetDebtLP = liquidityPosition[user].debtAsset;
            pos.debtAsset += assetDebtLP;
            pos.debtStable += liquidityPosition[user].debtStable;
            if (assetDebtLP > 0){
                if(!totalTraderExposureSign){
                    totalTraderExposure += assetDebtLP;
                } else {
                    totalTraderExposureSign = totalTraderExposure > assetDebtLP;
                    totalTraderExposure = UtilMath.diffAbs(totalTraderExposure, assetDebtLP);
                }
            }
        }
        delete liquidityPosition[user];

        if(UtilMath.diffAbs(pos.balanceAsset, pos.debtAsset)*price/oracleDecimals < 1e10){
            pos.balanceAsset = pos.debtAsset;
        }
        else 
        {
            // Repay asset debt
            if (pos.balanceAsset > pos.debtAsset) {
                unchecked {
                    pos.balanceAsset -= pos.debtAsset;
                }
                pos.debtAsset = 0;
                uint256 minTradeReturn = pos.balanceAsset*price/oracleDecimals * (1e5 - maxSlippage)/1e5;
                uint256 inputSize = pos.balanceAsset;
                uint256 tradeReturn = _trade(false, inputSize, minTradeReturn, globalLiquidityStable, frontendAddress, user, price);
                emit ExecutedTrade(user, false, inputSize, tradeReturn, price, 0);
            } else {
                unchecked {
                    pos.debtAsset -= pos.balanceAsset;
                }
                pos.balanceAsset = 0;
            }

            // Repay stable debt and fully close position
            
            if (pos.debtAsset > 0) {

                if(
                    block.timestamp > curveParameters.lastCurveUpdate + curveParameters.curveUpdateInterval ||
                    curveParameters.lastTradeDirection != true ||
                    curveParameters.lastValidatedPrice != price
                )
                {
                    curveParameters.lastCurveUpdate = block.timestamp;
                    curveParameters.lastTradeDirection = true;
                    curveParameters.lastValidatedPrice = price;
                    delete dy0;
                    delete dx0;
                }   
                uint256 inputNeeded = ((
                    CurveMath.computeExactAmountInLong(
                        pos.debtAsset + dx0,
                        price,
                        oracleDecimals,
                        globalLiquidityStable,
                        globalLiquidityStable,
                        globalLiquidityAsset,
                        curveParameters.longCurveParameterA,
                        curveParameters.longCurveParameterB,
                        1e8
                    ) - dy0 + flatTradingFee) * decimals.tradingFeeDecimals
                ) / (decimals.tradingFeeDecimals - tradingFee);

                uint256 minTradeReturn = inputNeeded*oracleDecimals/price * (1e5 - maxSlippage)/1e5;
                unchecked {
                    uint256 tradeReturn = _trade(true, inputNeeded, minTradeReturn, globalLiquidityAsset, frontendAddress, user, price);
                    emit ExecutedTrade(user, true, inputNeeded, tradeReturn, price, 0);
                }

                require(UtilMath.diffAbs(pos.balanceAsset, pos.debtAsset)*price/oracleDecimals < 1e10, "C0");
            }
        }

        // Calculate PnL
        (uint256 pnl, bool pnlSign) = calcPnL(user, price);

        if(_msgSender() == user && !pnlSign){
            require(pnl<getCollateral(user), "C1");  //If user is closing his own positions (not liquidation) he can't do so if he's in bad debt.
        }

        // Reset position
        delete userVirtualTraderPosition[user];
        delete autoCloseUsersData[user];

        // Update collateral
        if (getCollateral(user) < pnl && !pnlSign){
            (insuranceFund, insuranceFundSign) = UtilMath.signedSum(insuranceFund, insuranceFundSign, pnl - getCollateral(user), false);
        }
        IVault(vault).addPnlToCollateral(user, pnl, pnlSign);

        emit ClosedPosition(user, pnl, pnlSign);
    }
}