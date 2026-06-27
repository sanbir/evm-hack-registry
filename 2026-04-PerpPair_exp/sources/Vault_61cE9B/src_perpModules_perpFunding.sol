// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpConfig.sol";
import "../util/UtilMath.sol";
import "../util/MatrixMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "../CL_oracle_middleware/interfaces/IOracleMiddleware.sol";

abstract contract PerpFunding is PerpConfig {
    using Math for uint256;
    using SignedMath for int256;

    ///@dev Returns the oracle price for the asset.
    ///@return price Oracle price of the asset.
    function getPrice() public view returns (uint256) {
        return SafeCast.toUint256((IOracleMiddleware(oracle).getPrice()));
    }


    //Compute the (funding rate * AvgPrice) for a time period.
    ///@dev Computes the increase (or decrease) of the funding rate since the last update. Note that we do not actually store the funding rate, but the funding rate * price.
    ///@dev Important: the timestamp that is being passed in input must be in the past. It is meant to be the timestamp of the last update of the funding rate.
    ///@dev The timestamp can be used to have a "projection" of the funding rate, passing a timestamp equal to (block.timestamp - projectionLength). This way the funding rate is computed for a time laps (projectionLength)
    ///@param price Oracle price of the vAsset.
    ///@param timestamp Timestamp of the last update of the funding rate. Computes the update using the time difference (now-timestamp)
    ///@return localFundingRate Increase of the funding rate.
    ///@return localFundingRateSign Sign of the increase of the funding rate. True for positive, false for negative.
    function computeFundingRate(uint256 price, uint256 timestamp) public view returns (uint256, bool) {
        // 0. Ensure timestamp not in future
        require(timestamp <= block.timestamp, "F1");

        // 1. Load and combine liquidity
        uint256 assetLiq = globalLiquidityAsset;
        uint256 stableLiq = globalLiquidityStable;
        if (assetLiq + stableLiq == 0) return (0, true);

        // 2. Pre-calc price over oracle decimals with 18 decimals
        uint256 priceO = price * 1e18 / oracleDecimals;

        // 3. Compute unclamped coefficient numerator
        uint256 raw = totalTraderExposure * priceO/1e18 * decimals.fundingCDecimals * decimals.fundingRateDecimals;

        // 4. Compute denominator
        uint256 denomAsset = assetLiq * priceO/1e18;
        uint256 denom = fundingC * (denomAsset + stableLiq);

        // 5. Clamp coefficient
        UtilMath.ClampParameters memory cp = clampParameters;
        (uint256 coeff, bool coeffSign) = UtilMath.clamp(raw / denom, cp, totalTraderExposureSign);

        // 6. Time-weighted rate
        uint256 delta = block.timestamp - timestamp;
        uint256 newRate = coeff * delta / fundingInterval;

        // 7. Adjust by price and return
        return (priceO * newRate/1e18, coeffSign);
    }

    ///@dev Computes the increase (or decrease) of the funding fee of an user since the last update.
    ///@param user User to compute the funding fee for.
    function computeFundingFee(address user)
        public
        view
        returns (uint256 localFundingFee, bool localFundingFeeSign)
    {
        return _computeFundingFee(user, fundingRate, fundingRateSign);
    }

    ///@dev Computes the increase (or decrease) of the funding fee of an user since the last update, given appropriate fundingRate and fundingRateSign.
    ///@param user User to compute the funding fee for.
    ///@param _fundingRate Funding rate for the computation of the fee.
    ///@param _fundingRateSign Funding rate sign for the computation of the fee.
    function _computeFundingFee(address user, uint256 _fundingRate, bool _fundingRateSign)
        public
        view
        returns (uint256 localFundingFee, bool localFundingFeeSign)
    {
        int256 invLMD = decimals.liquidityMDecimals;
        LiquidityPosition storage lp = liquidityPosition[user];
        VirtualTraderPosition storage vp = userVirtualTraderPosition[user];
        
        (uint256 deltaF, bool deltaFSign) = UtilMath.signedSum(
            _fundingRate,
            _fundingRateSign,
            fundingRate,
            !fundingRateSign
        );
        int256 b = SafeCast.toInt256(deltaF * decimals.liquidityGDecimals / decimals.fundingRateDecimals);
        if (!deltaFSign) {
            b = -b;
        }

        //Compute DeltaG
        int256 deltaG0 = matrixRowG[0] - lp.snapshotG[0] + b * liquidityM[1][0] / invLMD;
        int256 deltaG1 = matrixRowG[1] - lp.snapshotG[1] + b * liquidityM[1][1] / invLMD;

        int256 LiqStable = int256(lp.initialStableBalance);
        int256 LiqAsset = int256(lp.initialAssetBalance);

        // Compute `star = DeltaG * M^-1(t0) * sharesVec`
        int256 x0 = (deltaG0 * lp.inverseSnapshotM[0][0] + deltaG1 * lp.inverseSnapshotM[1][0]) / invLMD;
        int256 x1 = (deltaG0 * lp.inverseSnapshotM[0][1] + deltaG1 * lp.inverseSnapshotM[1][1]) / invLMD;
        int256 star = (x0 * LiqStable + x1 * LiqAsset) / int256(decimals.liquidityGDecimals);

        //Reusing old variables
        (deltaF, deltaFSign) = UtilMath.signedSum(
            _fundingRate,
            _fundingRateSign,
            vp.initialFundingRate,
            !vp.initialFundingRateSign
        );

        // Compute `exposure`
        (uint256 exposure, bool exposureSign) = UtilMath.signedSum(
            vp.balanceAsset, true, vp.debtAsset + lp.debtAsset, false
        );

        unchecked {
            uint256 absStar = star >= 0 ? uint256(star) : uint256(-star);

            (localFundingFee, localFundingFeeSign) = UtilMath.signedSum(
                absStar, star >= 0, (exposure * deltaF) / decimals.fundingRateDecimals, deltaFSign == exposureSign
            );
        }
    }

    /// @notice Update funding rate and the G vector.
    /// @param price Oracle price for the asset.
    /// @param timestamp This timestamp will be passed to the funding rate computation function, it should be the LastOperationTimestamp.
    function _updateFG(uint256 price, uint256 timestamp) internal {

        int256 invLMD = decimals.liquidityMDecimals;
        //Compute Funding Rate
        (uint256 newFundingRate, bool newFundingRateSign) = computeFundingRate(price, timestamp);
        (fundingRate, fundingRateSign) =
            UtilMath.signedSum(fundingRate, fundingRateSign, newFundingRate, newFundingRateSign);

        //Compute B
        int256 b = SafeCast.toInt256(newFundingRate * decimals.liquidityGDecimals / decimals.fundingRateDecimals);
        if (!newFundingRateSign) {
            b = -b;
        }

        //Compute G
        matrixRowG[0] += b * liquidityM[1][0] / invLMD;
        matrixRowG[1] += b * liquidityM[1][1] / invLMD;
    }

    /// @notice Update price, funding rate and the G vector from external action.
    ///@param unverifiedReport Chainlink report of the current price
    function updateFG(bytes memory unverifiedReport) external {
        IOracleMiddleware(oracle).verifyReportIfNecessary(unverifiedReport);
        _updateFG(getPrice(), lastOperationTimestamp);
        lastOperationTimestamp = block.timestamp;
    }

}