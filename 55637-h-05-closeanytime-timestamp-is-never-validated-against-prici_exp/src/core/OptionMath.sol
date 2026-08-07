// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.4;
import "../Libraries/ABDKMath64x64.sol";

library OptionMath {
    using ABDKMath64x64 for int128;

    // 64x64 fixed point integer constants
    int128 internal constant ONE_64x64 = 0x10000000000000000;
    int128 internal constant THREE_64x64 = 0x30000000000000000;

    // 64x64 fixed point constants used in Choudhury’s approximation of the Black-Scholes CDF
    int128 private constant CDF_CONST_0 = 0x09109f285df452394; // 2260 / 3989
    int128 private constant CDF_CONST_1 = 0x19abac0ea1da65036; // 6400 / 3989
    int128 private constant CDF_CONST_2 = 0x0d3c84b78b749bd6b; // 3300 / 3989

    /**
     * @notice calculate the exponential decay coefficient for a given interval
     * @param oldTimestamp timestamp of previous update
     * @param newTimestamp current timestamp
     * @return 64x64 fixed point representation of exponential decay coefficient
     */
    function _decay(
        uint256 oldTimestamp,
        uint256 newTimestamp
    ) internal pure returns (int128) {
        return
            ONE_64x64.sub(
                (-ABDKMath64x64.divu(newTimestamp - oldTimestamp, 7 days)).exp()
            );
    }

    /**
     * @notice calculate Choudhury’s approximation of the Black-Scholes CDF
     * @param input64x64 64x64 fixed point representation of random variable
     * @return 64x64 fixed point representation of the approximated CDF of x
     */
    function _N(int128 input64x64) internal pure returns (int128) {
        // squaring via mul is cheaper than via pow
        int128 inputSquared64x64 = input64x64.mul(input64x64);

        int128 value64x64 = (-inputSquared64x64 >> 1).exp().div(
            CDF_CONST_0.add(CDF_CONST_1.mul(input64x64.abs())).add(
                CDF_CONST_2.mul(inputSquared64x64.add(THREE_64x64).sqrt())
            )
        );

        return input64x64 > 0 ? ONE_64x64.sub(value64x64) : value64x64;
    }

    /**
     * @notice calculate the price of an option using the Black-Scholes model
     * @param impliedVol uint256 representation of annualized impliedVol with a factor of 1e4
     * @param strike uint256 representation of strike price with a factor of 1e8
     * @param spot uint256 representation of spot price with a factor of 1e8
     * @param period uint256 representation of duration of option contract (in seconds)
     * @param isYes whether to price "call" or "put" option
     * @param isAbove whether to the user bets the price will stay above this strike or not
     * @return uint256 representation of Black-Scholes option price with a factor of 1e8
     */
    function blackScholesPriceBinary(
        uint256 impliedVol,
        uint256 strike,
        uint256 spot,
        uint256 period,
        bool isYes,
        bool isAbove
    ) internal pure returns (uint256) {
        int128 D8 = ABDKMath64x64.fromUInt(10 ** 8);
        int128 D4 = ABDKMath64x64.fromUInt(10 ** 4);
        int128 impliedVol64x64 = ABDKMath64x64.fromUInt(impliedVol).div(D4);
        int128 variance64x64 = impliedVol64x64.mul(impliedVol64x64);
        int128 strike64x64 = ABDKMath64x64.fromUInt(strike).div(D8);
        int128 spot64x64 = ABDKMath64x64.fromUInt(spot).div(D8);
        int128 maturity64x64 = ABDKMath64x64.fromUInt(period).div(
            ABDKMath64x64.fromUInt(365 days)
        );

        int128 premium64x64 = _blackScholesPriceBinary(
            variance64x64,
            strike64x64,
            spot64x64,
            maturity64x64,
            isYes,
            isAbove
        );
        return ABDKMath64x64.toUInt(premium64x64.mul(D8));
    }

    /**
     * @notice calculate the price of an option using the Black-Scholes model
     * @param varianceAnnualized64x64 64x64 fixed point representation of annualized variance
     * @param strike64x64 64x64 fixed point representation of strike price
     * @param spot64x64 64x64 fixed point representation of spot price
     * @param timeToMaturity64x64 64x64 fixed point representation of duration of option contract (in years)
     * @param isYes whether to price "call" or "put" option
     * @param isAbove whether to the user bets the price will stay above this strike or not
     * @return 64x64 fixed point representation of Black-Scholes option price
     */
    function _blackScholesPriceBinary(
        int128 varianceAnnualized64x64,
        int128 strike64x64,
        int128 spot64x64,
        int128 timeToMaturity64x64,
        bool isYes,
        bool isAbove
    ) internal pure returns (int128) {
        int128 cumulativeVariance64x64 = timeToMaturity64x64.mul(
            varianceAnnualized64x64
        );
        int128 cumulativeVarianceSqrt64x64 = cumulativeVariance64x64.sqrt();

        int128 d1_64x64 = spot64x64
            .div(strike64x64)
            .ln()
            .add(cumulativeVariance64x64 >> 1)
            .div(cumulativeVarianceSqrt64x64);
        int128 d2_64x64 = d1_64x64.sub(cumulativeVarianceSqrt64x64);

        if (isYes) {
            if (isAbove) {
                return _N(d2_64x64);
            } else {
                return _N(-d2_64x64);
            }
        } else {
            if (isAbove) {
                return ABDKMath64x64.fromUInt(1).sub(_N(d2_64x64));
            } else {
                return ABDKMath64x64.fromUInt(1).sub(_N(-d2_64x64));
            }
        }
    }
}
