// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../util/UtilMath.sol";

library FeeManager {
    using Math for uint256;
    using SignedMath for int256;

    /// @notice Compute the fee associated to the addition of liquidity (x,y)
    /// @notice $f = f_{max}\frac{\frac{f_{min}}{f_{max}} k + \left ( \frac{q - p}{p} \right )^2}{k + \left ( \frac{q - p}{p} \right )^2}$
    /// @notice k is global parameter, decides how steep the increase in the fee is.
    /// @notice $f_{min} \in [0,1]$ minimum fee for liquidity providing.
    /// @notice $f_{max} \in [0,1]$ maximum fee for liquidity providing.
    /// @notice p is the price from oracle.
    /// @notice q is $\frac{x}{y}$.
    /// @param stableLiquidity Amount of stable liquidity to be added (x).
    /// @param assetLiquidity Amount of asset liquidity to be added (y).
    /// @param initialStableLiquidity Amount of stable liquidity in the pool ($x_0$).
    /// @param initialAssetLiquidity Amount of asset liquidity in the pool ($y_0$).
    /// @param price Price obtained from oracles.
    /// @param oracleDecimals decimals of the oracle price.
    /// @param liquidityMaxFee maximum liquidity fee allowed.
    /// @param liquidityMinFee minimum liquidity fee allowed.
    /// @param liquidityFeeK k parameter for the liquidity fee formula.
    /// @param liquidityFeeDecimals decimals of the liquidity fee.
    /// @return fee Fee for liquidity deposit.
    function computeLiquidityDepositFee(
        uint256 stableLiquidity,
        uint256 assetLiquidity,
        uint256 initialStableLiquidity,
        uint256 initialAssetLiquidity,
        uint256 price,
        uint256 oracleDecimals,
        uint256 liquidityMaxFee,
        uint256 liquidityMinFee,
        uint256 liquidityFeeK,
        uint256 liquidityFeeDecimals
    )
        public
        pure
        returns (uint256 fee)
    {
        //if (stableLiquidity==0 || assetLiquidity==0 || liquidityMaxFee==0){
        //    return liquidityMaxFee;
        //}
        if (initialStableLiquidity == 0 || initialAssetLiquidity == 0) {
            return 0;
        }
        if (liquidityMaxFee == 0){
            return 0;
        }
        uint256 p;
        uint256 pPrime;
        uint256 pSecond;
        uint256 ratioDecimals = 1e18;
        if (initialStableLiquidity * ratioDecimals/ initialAssetLiquidity > price*ratioDecimals/oracleDecimals) {
            p = price*ratioDecimals/oracleDecimals;
            pPrime = initialStableLiquidity * ratioDecimals / initialAssetLiquidity;
            pSecond =
                (initialStableLiquidity + stableLiquidity) * ratioDecimals / (initialAssetLiquidity + assetLiquidity);
        } else {
            p = ratioDecimals * oracleDecimals / price;
            pPrime = initialAssetLiquidity * ratioDecimals / initialStableLiquidity;
            pSecond =
                (initialAssetLiquidity + assetLiquidity) * ratioDecimals / (initialStableLiquidity + stableLiquidity);
        }
        if (pSecond < pPrime && pSecond > p) {
            return liquidityMinFee;
        }
        uint256 relPriceDiff1Sq = UtilMath.diffAbs(pPrime, p) * UtilMath.diffAbs(pPrime, p) / p * ratioDecimals / p;
        uint256 relPriceDiff2Sq = UtilMath.diffAbs(pSecond, p) * UtilMath.diffAbs(pSecond, p) / p * ratioDecimals / p;
        uint256 num = liquidityMinFee * liquidityFeeK / liquidityMaxFee * (ratioDecimals + relPriceDiff1Sq) / ratioDecimals + relPriceDiff2Sq * liquidityFeeDecimals / ratioDecimals;
        uint256 den = liquidityFeeK * (ratioDecimals + relPriceDiff1Sq) / ratioDecimals
            + relPriceDiff2Sq * liquidityFeeDecimals / ratioDecimals;
        fee = num * liquidityMaxFee / den;
    }

    /// @notice Compute the fee associated to the removal of liquidity (x,y)
    /// @notice $f = f_{max}\frac{\frac{f_{min}}{f_{max}} k + \left ( \frac{q - p}{p} \right )^2}{k + \left ( \frac{q - p}{p} \right )^2}$
    /// @notice k is global parameter, decides how steep the increase in the fee is.
    /// @notice $f_{min} \in [0,1]$ minimum fee for liquidity providing.
    /// @notice $f_{max} \in [0,1]$ maximum fee for liquidity providing.
    /// @notice p is the price from oracle.
    /// @notice q is $\frac{x}{y}$.
    /// @param stableLiquidity Amount of stable liquidity to be removed (x).
    /// @param assetLiquidity Amount of asset liquidity to be removed (y).
    /// @param initialStableLiquidity Amount of stable liquidity in the pool ($x_0$).
    /// @param initialAssetLiquidity Amount of asset liquidity in the pool ($y_0$).
    /// @param price Price obtained from oracles.
    /// @param oracleDecimals decimals of the oracle price.
    /// @param liquidityMaxFee maximum liquidity fee allowed.
    /// @param liquidityMinFee minimum liquidity fee allowed.
    /// @param liquidityFeeK k parameter for the liquidity fee formula.
    /// @param liquidityFeeDecimals decimals of the liquidity fee.
    /// @return fee Fee for liquidity deposit.
    function computeLiquidityRemovalFee(
        uint256 stableLiquidity,
        uint256 assetLiquidity,
        uint256 initialStableLiquidity,
        uint256 initialAssetLiquidity,
        uint256 price,
        uint256 oracleDecimals,
        uint256 liquidityMaxFee,
        uint256 liquidityMinFee,
        uint256 liquidityFeeK,
        uint256 liquidityFeeDecimals
    )
        public
        pure
        returns (uint256 fee)
    {        
        if (liquidityMaxFee == 0){
            return 0;
        }
        //Fees are waived if almost no liquidity is left in the pool
        if ((initialStableLiquidity - stableLiquidity) < 10e18 && (initialAssetLiquidity - assetLiquidity) < 10e18*oracleDecimals/price){
            return 0;
        }
        uint256 p;
        uint256 pPrime;
        uint256 pSecond;
        uint256 ratioDecimals = 1e18;
        if (initialStableLiquidity * ratioDecimals / initialAssetLiquidity > price*ratioDecimals/oracleDecimals) {
            if(initialAssetLiquidity == assetLiquidity){
                return liquidityMaxFee;
            }
            p = price*ratioDecimals/oracleDecimals;
            pPrime = initialStableLiquidity * ratioDecimals / initialAssetLiquidity;
            pSecond =
                (initialStableLiquidity - stableLiquidity) * ratioDecimals / (initialAssetLiquidity - assetLiquidity);
        } else {
            if(initialStableLiquidity == stableLiquidity){
                return 0; //Returns zero fee. The reasoning is that the last LP leaving the system should not pay fees, since no other LPs would gain them.
            }
            p = ratioDecimals * oracleDecimals / price;
            pPrime = initialAssetLiquidity * ratioDecimals / initialStableLiquidity;
            pSecond =
                (initialAssetLiquidity - assetLiquidity) * ratioDecimals / (initialStableLiquidity - stableLiquidity);
        }
        if (pSecond < pPrime && pSecond > p) {
            return liquidityMinFee;
        }
        uint256 relPriceDiff1Sq = UtilMath.diffAbs(pPrime, p) * UtilMath.diffAbs(pPrime, p) / p * ratioDecimals / p;
        uint256 relPriceDiff2Sq = UtilMath.diffAbs(pSecond, p) * UtilMath.diffAbs(pSecond, p) / p * ratioDecimals / p;
        uint256 num = liquidityMinFee * liquidityFeeDecimals / liquidityMaxFee * liquidityFeeK / liquidityFeeDecimals
            * (ratioDecimals + relPriceDiff1Sq) / ratioDecimals + relPriceDiff2Sq * liquidityFeeDecimals / ratioDecimals;
        uint256 den = liquidityFeeK * (ratioDecimals + relPriceDiff1Sq) / ratioDecimals
            + relPriceDiff2Sq * liquidityFeeDecimals / ratioDecimals;
        fee = num * liquidityMaxFee / den;
    }
}
