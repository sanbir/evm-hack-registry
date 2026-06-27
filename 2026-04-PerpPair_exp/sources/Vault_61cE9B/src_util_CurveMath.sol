// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./UtilMath.sol";

/// @title Math for our dynamic-curve AMM
/// @author DenariaDev
/**
 * @notice This library is used to compute and solve the dynamic-curve equations:
 *     $$
 *     \begin{aligned}
 *         x = a_l y^3 + b_l y^2 + c_l y + d_l  \\
 *         y = a_s x^3 + b_s x^2 + c_s x + d_s 
 *     \end{aligned}
 *     $$
 *     Respectively for long and short trades.
 *     There are equations also for parameters for the inverse of these two, to compute the input asset/stable needed for an exact amount of stable/asset ouput, see report for details.
 *     $$
 *     \begin{aligned}
 *         y = a^\prime_l x^3 + b^\prime_l x^2 + c^\prime_l x + d^\prime_l  \\
 *         x = a^\prime_s y^3 + b^\prime_s y^2 + c^\prime_s y + d^\prime_s 
 *     \end{aligned}
 *     $$
 *     The equations are solved through Newton's method.
 *
 *     This library conatins some short error codes, the following table contains their extended description.
 *     | Error Code | Description                                                   |
 *     |------------|---------------------------------------------------------------|
 *     | APS1       | Division by zero error in AprimeShort                         |
 *     | APL1       | Division by zero error in AprimeLong                          |
 *     | NM1        | Error on newtonMethodCubic: converge to negative solution      |
 *     | NM2        | Error on newtonMethodCubic: didn't converge                    |
 * 
 */
library CurveMath {
    /* Compute long parameters */

    /// @notice Calculate lambda parameter for long trades.
    /// @notice $\lambda = p\cdot x_0 + dy $
    /// @param spotPrice Oracle price for the trade (p).
    /// @param size Amount of stable input for the trade (dy).
    /// @param initialAsset initial amount of asset ($x_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return lambda
    function computeLongLambda(
        uint256 spotPrice,
        uint256 size,
        uint256 initialAsset,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 lambda)
    {
        return spotPrice * initialAsset / oracleDecimals + size;
    }

    /// @notice Calculate square of asset liquidity for long trades.
    /// @param initialAsset initial amount of asset ($x_0$).
    /// @return xSquared $x_0^2$
    function computeXSquared(uint256 initialAsset) public pure returns (uint256 xSquared) {
        return initialAsset * initialAsset / 1e18;
    }

    /// @notice Calculate a parameter in the cubic equation for long and short trades
    /// @notice $a = \frac{\lambda^3}{L^2}$
    /// @notice $L$ is initial assets ($x_0$) for longs and initial stable ($y_0$) for shorts
    /// @param lambda Value of the parameter $\lambda$
    /// @param liqSquare Value of $L^2$
    /// @return a
    function computeA(uint256 lambda, uint256 liqSquare) public pure returns (uint256 a) {
        return lambda * lambda / 1e18 * lambda / liqSquare;
    }

    /// @notice Calculate $b_l$ parameter in the cubic equation for long trades
    /// @notice $b_l = \lambda p\frac{x_0^2p^2A}{px_0 + y_0} - \lambda^2 p (2B+3)$
    /// @param xSquare Square of the initial amount of assets ($x_0^2$).
    /// @param spotPrice Oracle price for the trade (p).
    /// @param lambda Value of the parameter $\lambda$.
    /// @param initialAsset Initial amount of asset ($x_0$).
    /// @param initialStable Initial amount of stable ($y_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param longCurveParameterA Value of parameter A in the dynamic-curve long invariant.
    /// @param longCurveParameterB Value of parameter B in the dynamic-curve long invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return b $b_l$
    /// @return bSign Sign of the parameter $b_l$. False is negative, true is positive.
    function computeLongB(
        uint256 xSquare,
        uint256 spotPrice,
        uint256 lambda,
        uint256 initialAsset,
        uint256 initialStable,
        uint256 oracleDecimals,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 b, bool bSign)
    {
        // Scale spotPrice up to 18 decimals if oracleDecimals < 18
        // This ensures we don't lose precision in later multiplications
        uint256 spotScaled = spotPrice * (1e18) / oracleDecimals;

        // Compute spotScaled^3 * xSquare (all 18 decimals)
        uint256 spot2 = spotScaled * spotScaled / 1e18;
        uint256 spot3 = spot2 * spotScaled / 1e18;
        uint256 n1 = xSquare * spot3 / 1e18;

        // num = A * λ * n1 / curveDecimals
        uint256 num = longCurveParameterA * lambda / curveParameterDecimals;
        num = num * n1 / 1e18;  // keep everything in 18-decimal fixed point

        // den = spotScaled * initialAsset + initialStable
        uint256 den = spotScaled * initialAsset / 1e18 + initialStable;

        // b1 = num / den (all in 18 decimals)
        uint256 b1 = num * 1e18 / den;

        // b2 = (λ^2 / 1e18) * spotScaled * (2B + 3C) / C
        uint256 lambdaSq = lambda * lambda / 1e18;
        uint256 factor = (2 * longCurveParameterB + 3 * curveParameterDecimals);
        uint256 b2 = lambdaSq * spotScaled / 1e18 * factor / curveParameterDecimals;

        // Inline diffAbs
        if (b1 >= b2) {
            b = b1 - b2;
            bSign = true;
        } else {
            b = b2 - b1;
            bSign = false;
        }
        
    }

    /// @notice Calculate $c_l$ parameter in the cubic equation for long trades
    /// @notice $c_l = \lambda\left( \frac{Ap^2x_0^2}{px_0+y_0}(y-y_0-px_0)+(B+1)^2p^2x_0^2+2p^2x_0^2(B+1) \right)$
    /// @param size Input size of the trade (dy).
    /// @param xSquare Square of the initial amount of assets ($x_0^2$).
    /// @param spotPrice Oracle price for the trade (p).
    /// @param lambda Value of the parameter $\lambda$.
    /// @param initialAsset Initial amount of asset ($x_0$).
    /// @param initialStable Initial amount of stable ($y_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param longCurveParameterA Value of parameter A in the dynamic-curve long invariant.
    /// @param longCurveParameterB Value of parameter B in the dynamic-curve long invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return c $c_l$
    /// @return cSign Sign of the parameter $c_l$. False is negative, true is positive.
    function computeLongC(
        uint256 size,
        uint256 xSquare,
        uint256 spotPrice,
        uint256 lambda,
        uint256 initialAsset,
        uint256 initialStable,
        uint256 oracleDecimals,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 c, bool cSign)
    {
        uint256 priceScaled = spotPrice*1e18/oracleDecimals;
        uint256 bPlusScaled = (longCurveParameterB + curveParameterDecimals) * 1e18 / curveParameterDecimals;
        //Note: sign of c1 is reversed as it is always negative in the formula
        uint256 c2 = xSquare * priceScaled/1e18 * priceScaled/1e18 * bPlusScaled/1e18 *(bPlusScaled + 2*1e18)/1e18;
        
        uint256 initialAssetValue = priceScaled * initialAsset / 1e18;
        bool positiveCase = initialAssetValue > size;
        uint256 diffAsset = positiveCase ? (initialAssetValue - size) : (size - initialAssetValue);
        uint256 nom = xSquare * longCurveParameterA/curveParameterDecimals * priceScaled/1e18 * priceScaled/1e18 * diffAsset;
        uint256 den = initialAssetValue + initialStable;
        uint256 c1 = nom/den;
        if(positiveCase){
            (uint256 diff, bool sign) = diffAbs(c1, c2);
            c = lambda * diff / 1e18;
            cSign = !sign;
        } else {
            c = lambda * (c1 + c2) / 1e18;
            cSign = true;
        }
    }

    /// @notice Calculate $d_l$ parameter in the cubic equation for long trades. Sign of d is always negative.
    /// @notice $d_l = -p^3x_0^4(B+1)^2$
    /// @param xSquare Square of the initial amount of assets ($x_0^2$).
    /// @param spotPrice Oracle price for the trade (p).
    /// @param initialAsset Initial amount of asset ($x_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param longCurveParameterB Value of parameter B in the dynamic-curve long invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return d $d_l$. Returns a uint, but sign is always negative.
    function computeLongD(
        uint256 xSquare,
        uint256 spotPrice,
        uint256 initialAsset,
        uint256 oracleDecimals,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 d)
    {
        uint256 scaledPrice = spotPrice * 1e18 / oracleDecimals;
        uint256 bPlusScaled = (longCurveParameterB + curveParameterDecimals) * 1e18 / curveParameterDecimals;

        d = xSquare * scaledPrice/1e18 * scaledPrice/1e18 * scaledPrice/1e18
            * initialAsset / 1e18 * initialAsset / 1e18 * bPlusScaled/1e18 * bPlusScaled/1e18;
    }

    /* Compute short parameters*/

    /// @notice Calculate lambda parameter for short trades.
    /// @notice $\lambda = y_0 + p\cdot dx $
    /// @param spotPrice Oracle price for the trade (p).
    /// @param size Amount of stable input for the trade (dx).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param initialStable initial amount of stable ($y_0$).
    /// @return lambda
    function computeShortLambda(
        uint256 spotPrice,
        uint256 size,
        uint256 oracleDecimals,
        uint256 initialStable
    )
        public
        pure
        returns (uint256 lambda)
    {
        return spotPrice * size / oracleDecimals + initialStable;
    }

    /// @notice Calculate square of asset liquidity for short trades.
    /// @param initialStable initial amount of asset ($y_0$).
    /// @return ySquared $y_0^2$
    function computeYSquare(uint256 initialStable) public pure returns (uint256 ySquared) {
        return initialStable * initialStable / 1e18;
    }

    /// @notice Calculate $b_s$ parameter in the cubic equation for short trades
    /// @notice $b_s = \frac{Ay_0^2}{px_0+y_0}\lambda -\lambda^2(2B+3)$
    /// @param ySquare Square of the initial amount of assets ($y_0^2$).
    /// @param spotPrice Oracle price for the trade (p).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param initialStable Initial amount of stable ($y_0$).
    /// @param initialAsset Initial amount of asset ($x_0$).
    /// @param lambda Value of the parameter $\lambda$.
    /// @param shortCurveParameterA Value of parameter A in the dynamic-curve short invariant.
    /// @param shortCurveParameterB Value of parameter B in the dynamic-curve short invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return b $b_s$
    /// @return bSign Sign of the parameter $b_s$. False is negative, true is positive.
    function computeShortB(
        uint256 ySquare,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialStable,
        uint256 initialAsset,
        uint256 lambda,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 b, bool bSign)
    {
        uint256 b1 = ySquare * shortCurveParameterA / curveParameterDecimals * lambda
            / (spotPrice * initialAsset / oracleDecimals + initialStable);
        uint256 b2 =
            lambda * lambda / 1e18 * (2 * shortCurveParameterB + 3 * curveParameterDecimals) / curveParameterDecimals;
        (b, bSign) = diffAbs(b1, b2);
    }

    /// @notice Calculate $c_s$ parameter in the cubic equation for short trades
    /// @notice $c_s = \lambda \left(\frac{Ay_0^2}{px_0+y_0}(pdx-y_0)+(B+1)^2y_0^2+2(B+1)y_0^2 \right)$
    /// @param size Input size of the trade (dx).
    /// @param ySquare Square of the initial amount of assets ($y_0^2$).
    /// @param spotPrice Oracle price for the trade (p).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param initialStable Initial amount of stable ($y_0$).
    /// @param initialAsset Initial amount of asset ($x_0$).
    /// @param lambda Value of the parameter $\lambda$.
    /// @param shortCurveParameterA Value of parameter A in the dynamic-curve short invariant.
    /// @param shortCurveParameterB Value of parameter B in the dynamic-curve short invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return c $c_s$
    /// @return cSign Sign of the parameter $c_s$. False is negative, true is positive.
    function computeShortC(
        uint256 size,
        uint256 ySquare,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialStable,
        uint256 initialAsset,
        uint256 lambda,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 c, bool cSign)
    {
        uint256 dO = oracleDecimals;
        uint256 dC = curveParameterDecimals;

        uint256 pSum = shortCurveParameterB + dC;
        uint256 part = ySquare * pSum / dC;

        //c2 = part * pSum / dC + 2 * part
        uint256 c2 = (part * pSum) / dC + (2 * part);

        uint256 spSize = spotPrice * size / dO;
        uint256 denom  = spotPrice * initialAsset / dO + initialStable;

        uint256 base = ySquare * shortCurveParameterA / dC;

        uint256 c1calc;
        bool   stableGT = initialStable > spSize;

        if (stableGT) {
            
            uint256 diff1 = initialStable - spSize;
            c1calc = base * diff1 / denom;                  
            // Inline diffAbs(c1, c2)
            uint256 absDiff = c1calc >= c2 ? c1calc - c2 : c2 - c1calc;
            c = lambda * absDiff / 1e18;                     
            
            cSign = c1calc <= c2;
        } else {
            
            uint256 diff2 = spSize - initialStable;
            c1calc = base * diff2 / denom;
            c = lambda * (c1calc + c2) / 1e18;
           
            cSign = true;
        }
    }

    /// @notice Calculate $d_s$ parameter in the cubic equation for short trades
    /// @notice $d_s = -y_0^4(B+1)^2$
    /// @param ySquare Square of the initial amount of assets ($y_0^2$).
    /// @param shortCurveParameterB Value of parameter B in the dynamic-curve short invariant.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return d $d_s$. Returns a uint, but sign is always negative.
    function computeShortD(
        uint256 ySquare,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 d)
    {
        uint256 bPlusScaled = (shortCurveParameterB + curveParameterDecimals)*1e18 / curveParameterDecimals;
        d = ySquare * ySquare / 1e18 * bPlusScaled/1e18 * bPlusScaled/1e18;
    }

    /// @notice Calculate $A^\prime$ parameter in the cubic equation for short trades
    /// @notice $A^\prime = \frac{Ay_0^4}{px_0+y_0}$
    /// @param A Value of parameter A in the dynamic-curve short invariant.
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param px0 Price*initialAsset ($p\cdot x_0$).
    /// @return aPrime
    function computeAPrimePramShort(uint256 A, uint256 y0, uint256 px0) public pure returns (uint256 aPrime) {
        require(px0 + y0 != 0, "APS1"); //Division by zero error in AprimeShort
        return (A * y0 / 1e18 * y0 / 1e18 * y0 / 1e18 * y0) / (px0 + y0);
    }

    /// @notice Calculate $\lambda$ parameter in the cubic equation for inverse short trades
    /// @notice $\lambda = y-y_0-px_0$
    /// @param y Total amount of stable ($y_0 + dy$).
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param px0 Price*initialAsset ($p\cdot x_0$).
    /// @return lambdaShortInv
    /// @return lambdaShortInvSign Sign of lambdaShort. False is negative, true is positive.
    function computeInverseLambdaShort(
        uint256 y,
        uint256 y0,
        uint256 px0
    )
        public
        pure
        returns (uint256 lambdaShortInv, bool lambdaShortInvSign)
    {
        return UtilMath.signedSum(y, true, y0 + px0, false);
    }

    /// @notice Calculate k parameter in the cubic equation for inverse short trades
    /// @notice $k = y_0-px_0$
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param px0 Price*initialAsset ($p\cdot x_0$).
    /// @return kShortInv
    /// @return kShortInvSign Sign of lambdaShort. False is negative, true is positive.
    function computeInverseKShort(
        uint256 y0,
        uint256 px0
    )
        public
        pure
        returns (uint256 kShortInv, bool kShortInvSign)
    {
        return UtilMath.signedSum(y0, true, px0, false);
    }

    /// @notice Calculate $a^\prime_s$ parameter in the cubic equation for inverse short trades
    /// @notice $a^\prime_s = \frac{y^3}{y_0^4}$
    /// @param y Total amount of stable ($y_0 + dy$).
    /// @param y0 Initial amount of stable ($y_0$).
    /// @return a $a^\prime_s$
    function computeInverseAShort(uint256 y, uint256 y0) public pure returns (uint256 a) {
        return y * y / y0 * y / y0 * 1e18 / y0 * 1e18 / y0;
    }

    /// @notice Calculate $b^\prime_s$ parameter in the cubic equation for inverse short trades
    /// @notice $b^\prime_s = \frac{A'y + 2y^3k - 2(B+1)y_0^2y^2 +(ky-y_0^2)y^2}{py_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param y Total amount of stable ($y_0 + dy$).
    /// @param p Oracle price for the trade (p).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param bParam Value of parameter B in the dynamic-curve short invariant.
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return b $b^\prime_s$
    /// @return bSign Sign of $b^\prime_s$. False is negative, true is positive.
    function computeInverseBShort(
        uint256 aPrime,
        uint256 y,
        uint256 p,
        uint256 k,
        bool kSign,
        uint256 bParam,
        uint256 y0,
        uint256 curveParameterDecimals,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 b, bool bSign)
    {
        uint256 term1 =
            aPrime * y / curveParameterDecimals * 1e18 / y0 * 1e18 / y0 * 1e18 / y0 * 1e18 / y0 * oracleDecimals / p;
        uint256 term2 = 2 * y * y / y0 * y / y0 * oracleDecimals / p * k / y0 * 1e18 / y0; //term2 sign is kSign
        uint256 term3 =
            2 * y * (bParam + curveParameterDecimals) / curveParameterDecimals * y / y0 * 1e18 / y0 * oracleDecimals / p; //Sign is -
        (uint256 term4_1, bool term4_1Sign) = UtilMath.signedSum(k * y, kSign, y0 * y0, false);
        uint256 term4 = term4_1 / 1e18 * y / y0 * y / y0 * 1e18 / y0 * 1e18 / y0 * oracleDecimals / p;
        (uint256 tot, bool totSign) = UtilMath.signedSum(term2, kSign, term4, term4_1Sign);
        (uint256 tot2, bool totSign2) = UtilMath.signedSum(term1, true, term3, false);
        return UtilMath.signedSum(tot, totSign, tot2, totSign2);
    }

    /// @notice Calculate $c^\prime_s$ parameter in the cubic equation for inverse short trades
    /// @notice $c^\prime_s = \frac{A'y(k+\lambda) + (B+1)^2y_0^4y + k^2y^3 -2(B+1)y_0^2y^2k + 2y^2k(ky-y_0^2) - 2(B+1)y_0^2y(ky-y_0^2)}{p^2y_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param p Oracle price for the trade (p).
    /// @param y Total amount of stable ($y_0 + dy$).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param lambda Parameter lambda.
    /// @param lambdaSign Sign of parameter lambda.
    /// @param bParam Value of parameter B in the dynamic-curve short invariant.
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return c $c^\prime_s$
    /// @return cSign Sign of $c^\prime_s$. False is negative, true is positive.
    function computeInverseCShort(
        uint256 aPrime,
        uint256 p,
        uint256 y,
        uint256 k,
        bool kSign,
        uint256 lambda,
        bool lambdaSign,
        uint256 bParam,
        uint256 y0,
        uint256 curveParameterDecimals,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 c, bool cSign)
    {
        (uint256 term1_1, bool term1_1Sign) = UtilMath.signedSum(k, kSign, lambda, lambdaSign);
        uint256 term1 = aPrime * 1e18 / curveParameterDecimals * y / y0 * term1_1 / y0 * 1e18 / y0 * 1e18 / y0
            * oracleDecimals / p * oracleDecimals / p; //Sign is term1_1Sign
        uint256 term2 = y * (bParam + curveParameterDecimals) / curveParameterDecimals
            * (bParam + curveParameterDecimals) / curveParameterDecimals * oracleDecimals / p * oracleDecimals / p;
        uint256 term3 = k * k / y0 * y / y0 * y / y0 * y / y0 * oracleDecimals / p * oracleDecimals / p; //Sign is always +
        uint256 term4 = 2 * y * y / y0 * (bParam + curveParameterDecimals) / curveParameterDecimals * k / y0
            * oracleDecimals / p * oracleDecimals / p; //Sign is -kSign
        (uint256 term5_1, bool term5_1Sign) = UtilMath.signedSum(k * y / 1e18, kSign, y0 * y0 / 1e18, false);
        uint256 term5 =
            2 * k * y / y0 * y / y0 * term5_1 / 1e18 * oracleDecimals / p * oracleDecimals / p * 1e18 / y0 * 1e18 / y0; //Sign is kSign*term5_1Sign
        uint256 term6 = 2 * y * (bParam + curveParameterDecimals) / curveParameterDecimals * term5_1 / 1e18
            * oracleDecimals / p * oracleDecimals / p * 1e18 / y0 * 1e18 / y0; //Sign is -term5_1Sign
        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, term1_1Sign, term4, !kSign);
        (uint256 tot2, bool totSign2) = UtilMath.signedSum(term5, kSign == term5_1Sign, term6, !term5_1Sign);
        (tot, totSign) = UtilMath.signedSum(tot, totSign, tot2, totSign2);
        return UtilMath.signedSum(tot, totSign, term2 + term3, true);
    }

    /// @notice Calculate $d^\prime_s$ parameter in the cubic equation for inverse short trades
    /// @notice $d^\prime_s = \frac{A'yk\lambda + (ky-y_0^2)(B+1)^2y_0^4 + (ky-y_0^2)k^2y^2 - 2(B+1)y_0^2yk(ky-y_0^2)}{p^3y_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param p Oracle price for the trade (p).
    /// @param y Total amount of stable ($y_0 + dy$).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param lambda Parameter lambda.
    /// @param lambdaSign Sign of parameter lambda.
    /// @param bParam Value of parameter B in the dynamic-curve short invariant.
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return d $d^\prime_s$
    /// @return dSign Sign of $d^\prime_s$. False is negative, true is positive.
    function computeInverseDShort(
        uint256 aPrime,
        uint256 p,
        uint256 y,
        uint256 k,
        bool kSign,
        uint256 lambda,
        bool lambdaSign,
        uint256 bParam,
        uint256 y0,
        uint256 curveParameterDecimals,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 d, bool dSign)
    {
        // Calculate each term of d
        uint256 term1 = y * 1e18 / y0 * aPrime / curveParameterDecimals * 1e18 / y0 * k / y0 * lambda / y0
            * oracleDecimals / p * oracleDecimals / p * oracleDecimals / p; //Sign is kSign==lambaSign
        (uint256 temp, bool tempSign) = UtilMath.signedSum(k * y / 1e18, kSign, y0 * y0 / 1e18, false);
        uint256 term2 = temp * (bParam + curveParameterDecimals) / curveParameterDecimals
            * (bParam + curveParameterDecimals) / curveParameterDecimals * oracleDecimals / p * oracleDecimals / p
            * oracleDecimals / p; //Sign is tempSign
        uint256 term3 =
            temp * k / y0 * k / y0 * y / y0 * y / y0 * oracleDecimals / p * oracleDecimals / p * oracleDecimals / p; // Sign is tempSign
        uint256 term4 = 2 * temp * (bParam + curveParameterDecimals) / curveParameterDecimals * y / y0 * k / y0
            * oracleDecimals / p * oracleDecimals / p * oracleDecimals / p; //Sign is -kSign==tempSign
        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, kSign == lambdaSign, term2, tempSign);
        (uint256 tot2, bool totSign2) = UtilMath.signedSum(term3, tempSign, term4, !(kSign == tempSign));
        // Sum all terms
        return UtilMath.signedSum(tot, totSign, tot2, totSign2);
    }

    /// @notice Calculate $A^\prime$ parameter in the cubic equation for long trades
    /// @notice $a^\prime_l = \frac{Ap^2x_0^4}{px_0+y_0}$
    /// @param A Value of parameter A in the dynamic-curve long invariant.
    /// @param p Oracle price for the trade (p).
    /// @param x0 Initial amount of asset ($x_0$).
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return aPrime
    function computeAPrimePramLong(
        uint256 A,
        uint256 p,
        uint256 x0,
        uint256 y0,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 aPrime)
    {
        require(p * x0 + y0 != 0, "APL1"); //Division by zero error in AprimeLong
        uint256 scaledP = p*1e18/oracleDecimals;
        return (A * scaledP/1e18 * scaledP/1e18 * x0 / 1e18 * x0 / 1e18 * x0 / 1e18 * x0)
            / (x0 * scaledP/1e18 + y0);
    }

    /// @notice Calculate $\lambda$ parameter in the cubic equation for long trades
    /// @notice $\lambda = p(x-x_0)-y_0$
    /// @param p Oracle price for the trade (p).
    /// @param x Total amount of stable ($x_0 + dx$).
    /// @param x0 Initial amount of asset ($x_0$).
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return lambda
    /// @return lambdaSign Sign of $\lambda$. False is negative, true is positive.
    function computeInverseLambdaLong(
        uint256 p,
        uint256 x,
        uint256 x0,
        uint256 y0,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 lambda, bool lambdaSign)
    {
        // λ = p * (x - x0) - y0
        return (p * (x0 - x) / oracleDecimals + y0, false);
    }

    /// @notice Calculate k parameter in the cubic equation for long trades
    /// @notice $k = px_0 - y_0$
    /// @param p Oracle price for the trade (p).
    /// @param x0 Initial amount of asset ($x_0$).
    /// @param y0 Initial amount of stable ($y_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @return k
    /// @return kSign Sign of k. False is negative, true is positive.
    function computeInverseKLong(
        uint256 p,
        uint256 x0,
        uint256 y0,
        uint256 oracleDecimals
    )
        public
        pure
        returns (uint256 k, bool kSign)
    {
        // k = p * x0 - y0
        return UtilMath.signedSum(p * x0 / oracleDecimals, true, y0, false);
    }

    /// @notice Calculate $a^\prime_l$ parameter in the cubic equation for long trades
    /// @notice $a^\prime_l = \frac{x^3}{x_0^4}$
    /// @param x Total amount of stable ($x_0 + dx$).
    /// @param x0 Initial amount of asset ($x_0$).
    /// @return a $a^\prime_l$
    function computeInverseALong(uint256 x, uint256 x0) public pure returns (uint256 a) {
        // a = x^3
        return x * x / x0 * x / x0 * 1e18 / x0 * 1e18 / x0;
    }

    /// @notice Calculate $b^\prime_l$ parameter in the cubic equation for inverse long trades
    /// @notice $b^\prime_s = \frac{A'x + 2x^3k - 2p(B+1)x_0^2x^2 +(kx-px_0^2)x^2}{x_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param x Total amount of stable ($x_0 + dx$).
    /// @param p Oracle price for the trade (p).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param bParam Value of parameter B in the dynamic-curve long invariant.
    /// @param x0 Initial amount of stable ($x_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return b $b^\prime_s$
    /// @return bSign Sign of $b^\prime_s$. False is negative, true is positive.
    function computeInverseBLong(
        uint256 aPrime,
        uint256 x,
        uint256 p,
        uint256 k,
        bool kSign,
        uint256 bParam,
        uint256 x0,
        uint256 oracleDecimals,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 b, bool bSign)
    {
        // b = A' * x + 2 * x^3 * k - 2 * p * (B + 1) * x0^2 * x^2 + (k * x - p * x0^2) * x^2
        uint256 term1 = aPrime * x / curveParameterDecimals * 1e18 / x0 * 1e18 / x0 * 1e18 / x0 * 1e18 / x0;
        uint256 term2 = 2 * x * x / x0 * x / x0 * k / 1e18 * 1e18 / x0 * 1e18 / x0; //Sign is kSign
        uint256 term3 = 2 * x * x / 1e18 * p / oracleDecimals * (bParam + curveParameterDecimals)
            / curveParameterDecimals * 1e18 / x0 * 1e18 / x0; //sign is -
        (uint256 term4_1, bool term4_1Sign) =
            UtilMath.signedSum(k * x / 1e18, kSign, p * x0 / oracleDecimals * x0 / 1e18, false);
        uint256 term4 = term4_1 * x / x0 * x / x0 * 1e18 / x0 * 1e18 / x0; //Sign is term4_1Sign
        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, true, term2, kSign);
        (tot, totSign) = UtilMath.signedSum(tot, totSign, term3, false);
        return UtilMath.signedSum(tot, totSign, term4, term4_1Sign);
    }

    /// @notice Calculate $c^\prime_l$ parameter in the cubic equation for inverse long trades
    /// @notice $c^\prime_l = \frac{A'x(k+\lambda) + (B+1)^2p^2x_0^4x + k^2x^3 -2(B+1)px_0^2x^2k + 2(kx-px_0^2)kx^2 - 2(B+1)(kx-px_0^2)px_0^2x}{x_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param x Total amount of stable ($x_0 + dx$).
    /// @param p Oracle price for the trade (p).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param lambda Parameter lambda.
    /// @param lambdaSign Sign of parameter lambda.
    /// @param bParam Value of parameter B in the dynamic-curve long invariant.
    /// @param x0 Initial amount of stable ($x_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return c $c^\prime_l$
    /// @return cSign Sign of $c^\prime_l$. False is negative, true is positive.
    function computeInverseCLong(
        uint256 aPrime,
        uint256 x,
        uint256 p,
        uint256 k,
        bool kSign,
        uint256 lambda,
        bool lambdaSign,
        uint256 bParam,
        uint256 x0,
        uint256 oracleDecimals,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256, bool)
    {
        // c = A' * x * (k + λ) + (B + 1)^2 * p^2 * x0^4 * x + k^2 * x^3
        //   - 2 * (B + 1) * p * x0^2 * x^2 * k + 2 * (k * x - p * x0^2) * k * x^2
        //   - 2 * (B + 1) * (k * x - p * x0^2) * p * x0^2 * x
        (uint256 term1_1, bool term1_1Sign) = UtilMath.signedSum(k, kSign, lambda, lambdaSign);
        uint256 term1 = aPrime * x / curveParameterDecimals * term1_1 / x0 * 1e18 / x0 * 1e18 / x0 * 1e18 / x0; //Sign is term1_1Sign
        uint256 term2 = x0 * x0 / 1e18 * (bParam + curveParameterDecimals) / curveParameterDecimals
            * (bParam + curveParameterDecimals) / curveParameterDecimals * p / oracleDecimals * p / oracleDecimals * x / x0
            * 1e18 / x0;
        uint256 term3 = k * k / 1e18 * x / x0 * x / x0 * x / x0 * 1e18 / x0; //sign is always +
        uint256 term4 = 2 * x * x / 1e18 * (bParam + curveParameterDecimals) / curveParameterDecimals * p
            / oracleDecimals * k / 1e18 * 1e18 / x0 * 1e18 / x0; //sign is -kSign
        (uint256 term5_1, bool term5_1Sign) =
            UtilMath.signedSum(k * x / 1e18, kSign, p * x0 / oracleDecimals * x0 / 1e18, false);
        uint256 term5 = 2 * term5_1 * k / 1e18 * x / x0 * x / x0 * 1e18 / x0 * 1e18 / x0; //sign is term5_1Sign==kSign
        uint256 term6 = 2 * x * (bParam + curveParameterDecimals) / curveParameterDecimals * term5_1 / 1e18 * p
            / oracleDecimals * 1e18 / x0 * 1e18 / x0; //sign is -term5_1Sign        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, term1_1sign, term2 + term3, true);
        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, term1_1Sign, term2 + term3, true);
        (uint256 tot2, bool totSign2) = UtilMath.signedSum(term4, !kSign, term5, term5_1Sign == kSign);
        (tot2, totSign2) = UtilMath.signedSum(tot2, totSign2, term6, !term5_1Sign);
        return UtilMath.signedSum(tot, totSign, tot2, totSign2);
    }

    /// @notice Calculate $d^\prime_l$ parameter in the cubic equation for inverse long trades
    /// @notice $d^\prime_l = \frac{A'xk\lambda + (kx-px_0^2)(B+1)^2p^2x_0^4 + (kx-px_0^2)k^2x^2 - 2(B+1)px_0^2xk(kx-px_0^2)}{x_0^4}$
    /// @param aPrime Parameter $A^\prime$.
    /// @param x Total amount of stable ($x_0 + dx$).
    /// @param p Oracle price for the trade (p).
    /// @param k Parameter k.
    /// @param kSign Sign of parameter k.
    /// @param lambda Parameter lambda.
    /// @param lambdaSign Sign of parameter lambda.
    /// @param bParam Value of parameter B in the dynamic-curve long invariant.
    /// @param x0 Initial amount of stable ($x_0$).
    /// @param oracleDecimals Oracle decimals used for the uint value of the oracle price.
    /// @param curveParameterDecimals decimals used for the uint value of A and B.
    /// @return d $d^\prime_l$
    /// @return dSign Sign of $d^\prime_l$. False is negative, true is positive.
    function computeInverseDLong(
        uint256 aPrime,
        uint256 x,
        uint256 p,
        uint256 k,
        bool kSign,
        uint256 lambda,
        bool lambdaSign,
        uint256 bParam,
        uint256 x0,
        uint256 oracleDecimals,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 d, bool dSign)
    {
        // d = A' * x * k * λ + (k * x - p * x0^2) * (B + 1)^2 * p^2 * x0^4
        //   + (k * x - p * x0^2) * k^2 * x^2
        //   - 2 * (B + 1) * p * x0^2 * k * (k * x - p * x0^2) * x
        uint256 term1 = x * aPrime / x0 * k / 1e18 * lambda / x0 * 1e18 / x0 * 1e18 / x0 * 1e18 / oracleDecimals; //Sign is kSign==lambdaSign
        (uint256 term2_1, bool term2_1Sign) =
            UtilMath.signedSum(k * x / 1e18, kSign, p * x0 / oracleDecimals * x0 / 1e18, false);
        uint256 term2 = term2_1 * (bParam + curveParameterDecimals) / curveParameterDecimals
            * (bParam + curveParameterDecimals) / curveParameterDecimals * p / oracleDecimals * p / oracleDecimals; //Sign is term2_1Sign
        uint256 term3 = term2_1 * k / 1e18 * k / 1e18 * x / x0 * x / x0 * 1e18 / x0 * 1e18 / x0; //Sign is term2_1Sign
        uint256 term4 = 2 * term2_1 * x / 1e18 * (bParam + curveParameterDecimals) / curveParameterDecimals * p
            / oracleDecimals * k / 1e18 * 1e18 / x0 * 1e18 / x0; //Sign is - kSign==term2_1Sign
        (uint256 tot, bool totSign) = UtilMath.signedSum(term1, kSign == lambdaSign, term2 + term3, term2_1Sign);
        return UtilMath.signedSum(tot, totSign, term4, !kSign == term2_1Sign);
    }

    //Compute amount of vAsset that correspond to size vStable
    ///@notice Compute amount of vAsset that correspond to size vStable
    ///@param size Amount of virtual stable input to the trade.
    ///@param spotPrice Oracle price of the asset.
    ///@param oracleDecimals Decimals of the price.
    ///@param initialGuess Initial guess for the solution of the newton's method.
    ///@param globalLiquidityStable Total stable liquidity in the pool.
    ///@param globalLiquidityAsset Total asset liquidity in the pool.
    ///@param longCurveParameterA Curve parameter A for longs.
    ///@param longCurveParameterB Curve parameter B for longs.
    ///@param curveParameterDecimals Decimals for curve parameters.
    ///@return outputSize Virtual assets returned from the trade.
    function computeLongReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 outputSize)
    {
        uint256 prc = spotPrice;
        uint256 globAss = globalLiquidityAsset;
        uint256 oracleDec = oracleDecimals;
        uint256 lambda = computeLongLambda(prc, size, globAss, oracleDec); //1e18
        uint256 xSquare = computeXSquared(globAss); //1e18

        uint256 a = computeA(lambda, xSquare); //1e18
        (uint256 b, bool bSign) = computeLongB(
            xSquare,
            prc,
            lambda,
            globAss,
            globalLiquidityStable,
            oracleDec,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        (uint256 c, bool cSign) = computeLongC(
            size,
            xSquare,
            prc,
            lambda,
            globAss,
            globalLiquidityStable,
            oracleDec,
            longCurveParameterA,
            longCurveParameterB,
            curveParameterDecimals
        );
        //opposite sign to equation in notes because d is always negative
        uint256 d = computeLongD(
            xSquare, prc, globAss, oracleDec, longCurveParameterB, curveParameterDecimals
        );
        //Compute the new liquidity after the exchange
        uint256 newAsset = newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, false);
        //return the exchanged vAsset
        return (globAss - newAsset);
    }

    //Compute amount of vStable that correspond to size vAsset
    ///@notice Compute amount of vStable that correspond to size vAsset
    ///@param size Amount of virtual asset input to the trade.
    ///@param spotPrice Oracle price of the asset.
    ///@param oracleDecimals Decimals of the price.
    ///@param initialGuess Initial guess for the solution of the newton's method.
    ///@param globalLiquidityStable Total stable liquidity in the pool.
    ///@param globalLiquidityAsset Total asset liquidity in the pool.
    ///@param shortCurveParameterA Curve parameter A for shorts.
    ///@param shortCurveParameterB Curve parameter B for shorts.
    ///@param curveParameterDecimals Decimals for curve parameters.
    ///@return outputSize Virtual stable returned from the trade.
    function computeShortReturn(
        uint256 size,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256 outputSize)
    {
        uint256 lambda = computeShortLambda(spotPrice, size, oracleDecimals, globalLiquidityStable); //1e18
        uint256 ySquare = computeYSquare(globalLiquidityStable); //1e18

        uint256 a = computeA(lambda, ySquare); //1e18
        (uint256 b, bool bSign) = computeShortB(
            ySquare,
            spotPrice,
            oracleDecimals,
            globalLiquidityStable,
            globalLiquidityAsset,
            lambda,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );
        (uint256 c, bool cSign) = computeShortC(
            size,
            ySquare,
            spotPrice,
            oracleDecimals,
            globalLiquidityStable,
            globalLiquidityAsset,
            lambda,
            shortCurveParameterA,
            shortCurveParameterB,
            curveParameterDecimals
        );

        //opposite sign to equation in notes because d is always negative
        uint256 d = computeShortD(ySquare, shortCurveParameterB, curveParameterDecimals);
        //compute new Stable liquidity after exchange
        uint256 newStable = newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, false);
        //return the amount of stable exchanged
        return (globalLiquidityStable - newStable);
    }

    ///@notice Compute amount of vStable that are needed in input for an output of OutputSize vAsset
    ///@param outputSize Amount of virtual asset desired in output of the trade.
    ///@param spotPrice Oracle price of the asset.
    ///@param oracleDecimals Decimals of the price.
    ///@param initialGuess Initial guess for the solution of the newton's method.
    ///@param globalLiquidityStable Total stable liquidity in the pool.
    ///@param globalLiquidityAsset Total asset liquidity in the pool.
    ///@param longCurveParameterA Curve parameter A for longs.
    ///@param longCurveParameterB Curve parameter B for longs.
    ///@param curveParameterDecimals Decimals for curve parameters.
    ///@return inputSize Virtual stable needed in input to the trade.
    function computeExactAmountInLong(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 longCurveParameterA,
        uint256 longCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256)
    {
        require(globalLiquidityAsset >= outputSize, "INVL1"); //Requesting more asset than available
        uint256 aPrime = computeAPrimePramLong(
            longCurveParameterA, spotPrice, globalLiquidityAsset, globalLiquidityStable, oracleDecimals
        );
        (uint256 lambda, bool lambdaSign) = computeInverseLambdaLong(
            spotPrice, globalLiquidityAsset - outputSize, globalLiquidityAsset, globalLiquidityStable, oracleDecimals
        );
        (uint256 k, bool kSign) =
            computeInverseKLong(spotPrice, globalLiquidityAsset, globalLiquidityStable, oracleDecimals);
        
        uint256 a = computeInverseALong(globalLiquidityAsset - outputSize, globalLiquidityAsset);
        (uint256 b, bool bSign) = computeInverseBLong(
            aPrime,
            globalLiquidityAsset - outputSize,
            spotPrice,
            k,
            kSign,
            longCurveParameterB,
            globalLiquidityAsset,
            oracleDecimals,
            curveParameterDecimals
        );
        (uint256 c, bool cSign) = computeInverseCLong(
            aPrime,
            globalLiquidityAsset - outputSize,
            spotPrice,
            k,
            kSign,
            lambda,
            lambdaSign,
            longCurveParameterB,
            globalLiquidityAsset,
            oracleDecimals,
            curveParameterDecimals
        );
        (uint256 d, bool dSign) = computeInverseDLong(
            aPrime,
            globalLiquidityAsset - outputSize,
            spotPrice,
            k,
            kSign,
            lambda,
            lambdaSign,
            longCurveParameterB,
            globalLiquidityAsset,
            oracleDecimals,
            curveParameterDecimals
        );

        uint256 newStable = newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, dSign);
        return newStable - globalLiquidityStable;
    }

    ///@notice Compute amount of vAsset that are needed in input for an output of OutputSize vStable
    ///@param outputSize Amount of virtual stable desired in output of the trade.
    ///@param spotPrice Oracle price of the asset.
    ///@param oracleDecimals Decimals of the price.
    ///@param initialGuess Initial guess for the solution of the newton's method.
    ///@param globalLiquidityStable Total stable liquidity in the pool.
    ///@param globalLiquidityAsset Total asset liquidity in the pool.
    ///@param shortCurveParameterA Curve parameter A for shorts.
    ///@param shortCurveParameterB Curve parameter B for shorts.
    ///@param curveParameterDecimals Decimals for curve parameters.
    ///@return inputSize Virtual asset needed in input to the trade.
    function computeExactAmountInShort(
        uint256 outputSize,
        uint256 spotPrice,
        uint256 oracleDecimals,
        uint256 initialGuess,
        uint256 globalLiquidityStable,
        uint256 globalLiquidityAsset,
        uint256 shortCurveParameterA,
        uint256 shortCurveParameterB,
        uint256 curveParameterDecimals
    )
        public
        pure
        returns (uint256)
    {
        require(globalLiquidityStable >= outputSize, "INVS1"); //Requesting more stable than available
        uint256 aPrime = computeAPrimePramShort(
            shortCurveParameterA, globalLiquidityStable, spotPrice * globalLiquidityAsset / oracleDecimals
        );
        (uint256 lambda, bool lambdaSign) = computeInverseLambdaShort(
            globalLiquidityStable - outputSize, globalLiquidityStable, spotPrice * globalLiquidityAsset / oracleDecimals
        );
        (uint256 k, bool kSign) =
            computeInverseKShort(globalLiquidityStable, spotPrice * globalLiquidityAsset / oracleDecimals);

        uint256 a = computeInverseAShort(globalLiquidityStable - outputSize, globalLiquidityStable);
        (uint256 b, bool bSign) = computeInverseBShort(
            aPrime,
            globalLiquidityStable - outputSize,
            spotPrice,
            k,
            kSign,
            shortCurveParameterB,
            globalLiquidityStable,
            curveParameterDecimals,
            oracleDecimals
        );
        (uint256 c, bool cSign) = computeInverseCShort(
            aPrime,
            spotPrice,
            globalLiquidityStable - outputSize,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            globalLiquidityStable,
            curveParameterDecimals,
            oracleDecimals
        );
        (uint256 d, bool dSign) = computeInverseDShort(
            aPrime,
            spotPrice,
            globalLiquidityStable - outputSize,
            k,
            kSign,
            lambda,
            lambdaSign,
            shortCurveParameterB,
            globalLiquidityStable,
            curveParameterDecimals,
            oracleDecimals
        );

        uint256 newAsset = newtonMethodCubic(initialGuess, a, b, c, d, bSign, cSign, dSign);
        return newAsset - globalLiquidityAsset;
    }

    function diffAbs(uint256 a, uint256 b) internal pure returns (uint256, bool) {
        return a >= b ? (a - b, true) : (b - a, false);
    }

    /// @notice Use newton method to compute solutions to a third degree equation $y = ax^3 + bx^2 + cx + d$.
    /// @param initialGuess initial value for the iterative process.
    /// @param a a parameter of the cubic equation.
    /// @param b b parameter of the cubic equation.
    /// @param c c parameter of the cubic equation.
    /// @param d d parameter of the cubic equation.
    /// @param bSign sign of the parameter b.
    /// @param cSign sign of the parameter c.
    /// @param dSign sign of the parameter d.
    /// @return y
    function newtonMethodCubic(
        uint256 initialGuess,
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        bool bSign,
        bool cSign,
        bool dSign
    ) public pure returns (uint256 y) {
        uint256 x = initialGuess;
        uint256 x_prev;

        for (uint256 _i = 0; _i < 255;) {
            x_prev = x;

            uint256 x2;
            uint256 x3;
            uint256 ax2;
            uint256 ax3;
            uint256 bx2;
            uint256 bx;
            uint256 cx;

            assembly {
                x2 := div(mul(x_prev, x_prev), 1000000000000000000)
                x3 := div(mul(x2, x_prev), 1000000000000000000)
                ax2 := div(mul(a, x2), 1000000000000000000)
                ax3 := div(mul(a, x3), 1000000000000000000)
                bx2 := div(mul(b, x2), 1000000000000000000)
                bx := div(mul(b, x_prev), 1000000000000000000)
                cx := div(mul(c, x_prev), 1000000000000000000)
            }

            if (bSign && cSign && dSign) {
                uint256 fx = ax3 + bx2 + cx + d;
                uint256 fpx = 3 * ax2 + 2 * bx + c;
                require(x_prev > fx * 1e18 / fpx, "NM1");
                x = x_prev - fx * 1e18 / fpx;

            } else if (bSign && !cSign && dSign) {
                uint256 lhs = ax3 + bx2 + d;
                uint256 rhs = cx;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2 + 2 * bx;
                uint256 rhs_p = c;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (!bSign && cSign && dSign) {
                uint256 lhs = ax3 + cx + d;
                uint256 rhs = bx2;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2 + c;
                uint256 rhs_p = 2 * bx;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    require(x_prev > fx * 1e18 / fpx, "NM1");
                    x = x_prev - fx * 1e18 / fpx;
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (!bSign && !cSign && dSign) {
                uint256 lhs = ax3 + d;
                uint256 rhs = bx2 + cx;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2;
                uint256 rhs_p = 2 * bx + c;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (bSign && cSign && !dSign) {
                uint256 lhs = ax3 + bx2 + cx;
                uint256 rhs = d;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 fpx = 3 * ax2 + 2 * bx + c;

                if (fxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (bSign && !cSign && !dSign) {
                uint256 lhs = ax3 + bx2;
                uint256 rhs = d + cx;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2 + 2 * bx;
                uint256 rhs_p = c;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (!bSign && cSign && !dSign) {
                uint256 lhs = ax3 + cx;
                uint256 rhs = d + bx2;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2 + c;
                uint256 rhs_p = 2 * bx;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }

            } else if (!bSign && !cSign && !dSign) {
                uint256 lhs = ax3;
                uint256 rhs = d + bx2 + cx;
                (uint256 fx, bool fxSign) = diffAbs(lhs, rhs);

                uint256 lhs_p = 3 * ax2;
                uint256 rhs_p = 2 * bx + c;
                (uint256 fpx, bool fpxSign) = diffAbs(lhs_p, rhs_p);

                if (fxSign == fpxSign) {
                    if (x_prev > fx * 1e18 / fpx) {
                        x = x_prev - fx * 1e18 / fpx;
                    } else {
                        x = 0;
                    }
                } else {
                    x = x_prev + fx * 1e18 / fpx;
                }
            }

            uint256 diff;
            assembly {
                switch gt(x, x_prev)
                case 1 {
                    diff := sub(x, x_prev)
                }
                default {
                    diff := sub(x_prev, x)
                }
            }
            if (diff <= 1e10) {
                return x;
            }
            unchecked {
                ++_i;
            }
        }
        revert("NM2"); // Didn't converge
    }
}
