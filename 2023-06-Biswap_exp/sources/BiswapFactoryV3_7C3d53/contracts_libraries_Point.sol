// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

library Point {

    struct Data {
        uint128 liquidSum;
        // value to add when pass this slot from left to right
        // value to dec when pass this slot from right to left
        int128 liquidDelta;
        // if pointPrice < currPrice
        //    value = sigma(feeScaleX(p)), which p < pointPrice
        // if pointPrice >= currPrice
        //    value = sigma(feeScaleX(p)), which p >= pointPrice
        uint256 accFeeXOut_128;
        // similar to accFeeXOut_128
        uint256 accFeeYOut_128;
        // whether the point is endpoint of a liquid segment
        bool isEndpt;
        //feeVote delta value to add or dec fee vote delta when pass this slot
        uint240 feeTimesL;
        //accumulated farm points on point calculated similar to accFeeXOut_128
        uint256 accFPOut_128;
    }

    function _getFeeScaleL(
        int24 endpt,
        int24 currpt,
        uint256 feeScale_128,
        uint256 feeScaleBeyond_128
    ) internal pure returns (uint256 feeScaleL_128) {
        if (endpt <= currpt) {
            feeScaleL_128 = feeScaleBeyond_128;
        } else {
            assembly {
                feeScaleL_128:= sub(feeScale_128, feeScaleBeyond_128)
            }
        }
    }
    function _getFeeScaleGE(
        int24 endpt,
        int24 currpt,
        uint256 feeScale_128,
        uint256 feeScaleBeyond_128
    ) internal pure returns (uint256 feeScaleGE_128) {
        if (endpt > currpt) {
            feeScaleGE_128 = feeScaleBeyond_128;
        } else {
            assembly {
                feeScaleGE_128:= sub(feeScale_128, feeScaleBeyond_128)
            }
        }
    }
    /// @dev Calculate fee scale within range [pl, pr).
    /// @param axes collection of points of liquidities
    /// @param pl left endpoint of the segment
    /// @param pr right endpoint of the segment
    /// @param currpt point of the curr price
    /// @param feeScaleX_128 total fee scale of token x accumulated of the exchange
    /// @param feeScaleY_128 similar to feeScaleX_128
    /// @param fpScale_128 similar to feeScales
    /// @return accFeeXIn_128 accFeeYIn_128 fee scale of token x and token y within range [pl, pr)
    function getSubFeeScale(
        mapping(int24 =>Point.Data) storage axes,
        int24 pl,
        int24 pr,
        int24 currpt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128,
        uint256 fpScale_128
    ) internal view returns (uint256 accFeeXIn_128, uint256 accFeeYIn_128, uint256 accFPIn_128) {
        Point.Data storage plData = axes[pl];
        Point.Data storage prData = axes[pr];
        unchecked{
            accFeeXIn_128 = feeScaleX_128 -
            _getFeeScaleL(pl, currpt, feeScaleX_128, plData.accFeeXOut_128) -
            _getFeeScaleGE(pr, currpt, feeScaleX_128, prData.accFeeXOut_128);
            accFeeYIn_128 = feeScaleY_128 -
            _getFeeScaleL(pl, currpt, feeScaleY_128, plData.accFeeYOut_128) -
            _getFeeScaleGE(pr, currpt, feeScaleY_128, prData.accFeeYOut_128);
            accFPIn_128 = fpScale_128 -
            _getFeeScaleL(pl, currpt, fpScale_128, plData.accFPOut_128) -
            _getFeeScaleGE(pr, currpt, fpScale_128, prData.accFPOut_128);
        }
    }

    /// @dev Update and endpoint of a liquidity segment.
    /// @param axes collections of points
    /// @param endpt endpoint of a segment
    /// @param isLeft left or right endpoint
    /// @param currpt point of current price
    /// @param delta >0 for add liquidity and <0 for dec
    /// @param liquidLimPt liquid limit per point
    /// @param feeScaleX_128 total fee scale of token x
    /// @param feeScaleY_128 total fee scale of token y
    function updateEndpoint(
        mapping(int24 =>Point.Data) storage axes,
        int24 endpt,
        bool isLeft,
        int24 currpt,
        int128 delta,
        uint128 liquidLimPt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128,
        uint16 feeToVote,
        uint256 fpScale_128
    ) internal returns (bool new_or_erase) {
        Point.Data storage data = axes[endpt];
        uint128 liquidAccBefore = data.liquidSum;
        // delta cannot be 0
        require(delta!=0, "D0");
        // liquidity acc cannot overflow
        uint128 liquidAccAfter;
        uint240 feeTimesL;

        if (delta > 0) {
            liquidAccAfter = liquidAccBefore + uint128(delta);
            feeTimesL = feeToVote * uint128(delta);
            require(liquidAccAfter > liquidAccBefore, "LAAO");
        } else {
            liquidAccAfter = liquidAccBefore - uint128(-delta);
            feeTimesL = feeToVote * uint128(-delta);
            require(liquidAccAfter < liquidAccBefore, "LASO");
        }
        require(liquidAccAfter <= liquidLimPt, "L LIM PT");
        data.liquidSum = liquidAccAfter;

        int128 liquidDeltaBefore = data.liquidDelta;
        data.liquidDelta = isLeft ? data.liquidDelta + delta : data.liquidDelta - delta;

        if((liquidDeltaBefore < 0) != (isLeft != (delta < 0))){
            data.feeTimesL += feeTimesL;
        } else {
            data.feeTimesL = abs(data.feeTimesL, feeTimesL);
        }

        new_or_erase = false;
        if (liquidAccBefore == 0) {
            // a new endpoint of certain segment
            new_or_erase = true;
            data.isEndpt = true;

            // for either left point or right point of the liquidity segment
            // the feeScaleBeyond can be initialized to arbitrary value
            // we here set the initial val to total feeScale to delay overflow
            if (endpt >= currpt) {
                data.accFeeXOut_128 = feeScaleX_128;
                data.accFeeYOut_128 = feeScaleY_128;
                data.accFPOut_128 = fpScale_128;
            }
        } else if (liquidAccAfter == 0) {
            // no segment use this endpoint
            new_or_erase = true;
            data.isEndpt = false;
        }
        return new_or_erase;
    }

    function abs(uint240 a, uint240 b) internal pure returns(uint240){
        return a > b ? a - b : b - a;
    }

    /// @dev Pass the endpoint, change the feescale beyond the price.
    /// @param endpt endpoint to change
    /// @param feeScaleX_128 total fee scale of token x
    /// @param feeScaleY_128 total fee scale of token y
    /// @param fpScale_128 total fp scale
    function passEndpoint(
        Point.Data storage endpt,
        uint256 feeScaleX_128,
        uint256 feeScaleY_128,
        uint256 fpScale_128
    ) internal {
        uint256 accFeeXOut_128 = endpt.accFeeXOut_128;
        uint256 accFeeYOut_128 = endpt.accFeeYOut_128;
        uint256 accFpOut_128 = endpt.accFPOut_128;
        assembly {
            accFeeXOut_128 := sub(feeScaleX_128, accFeeXOut_128)
            accFeeYOut_128 := sub(feeScaleY_128, accFeeYOut_128)
            accFpOut_128 := sub(fpScale_128, accFpOut_128)
        }
        endpt.accFeeXOut_128 = accFeeXOut_128;
        endpt.accFeeYOut_128 = accFeeYOut_128;
        endpt.accFPOut_128 = accFpOut_128;
    }

}
