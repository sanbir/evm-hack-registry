// SPDX-License-Identifier: BSL-1.1
// Copyright Itos Inc 2023
pragma solidity ^0.8.17;

// Smooth Rate Curve Equations
// q - utilization ratio
// F(q) - fee rate is a hyperbolic function of the utilization ratio
//
// Parameters
// f_b - base fee rate
// f_t - target fee rate
// f_m - maximum fee rate
// q_t - target utilization
// q_m - max utilization
//
// where
// f_b, f_t, f_b exist in R
// q, q_t, q_m exist in [0, 1]
//
// alpha =  q_t / (q_m * (q_m - q_t) * (f_t - f_b))
// beta = f_b - 1 / (alpha * q_m)
//
// F(q) = min(beta + 1 / (alpha * (q_m - q)), f_m)

// alpha [10_000, 0]

// SPR factor 31536000 = 365 * 24 * 60 * 60
// APR of 0.001% = 0.00001
// as a SPR = 0.00001 / 31536000 =  0.00000000000031709791983764586504312531709791983764586504312531709791983

struct SmoothRateCurveConfig {
    uint128 invAlphaX128;
    uint128 betaX64; // inludes the BETA_OFFSET, otherwise value could be negative
    uint128 maxUtilX64;
    uint128 maxRateX64;
}

library SmoothRateCurveLib {
    /// We use a beta offset so we can do all our operations in uint.
    uint128 private constant BETA_OFFSET = 1 << 64;

    error BetaOverflowsOffset(int128 betaX64);
    error MaxRateAboveCurve(uint128 maxRateX64, uint128 calculatedMaxRateX64);
    error InvAlphaIsZero();
    error MaxUtilIsZero();
    error MaxRateIsZero();

    function calculateRateX64(
        SmoothRateCurveConfig memory self,
        uint128 utilX64
    ) internal pure returns (uint128 rateX64) {
        if (utilX64 >= self.maxUtilX64) {
            return self.maxRateX64;
        }

        uint128 calculatedRateX64 = self.betaX64 + self.invAlphaX128 / (self.maxUtilX64 - utilX64) - BETA_OFFSET;
        if (calculatedRateX64 > self.maxRateX64) {
            return self.maxRateX64;
        }
        return calculatedRateX64;
    }

    /// @notice Allows custom configs to be created with some safety checks.
    function initializeConfig(
        SmoothRateCurveConfig memory self,
        uint128 invAlphaX128,
        int128 betaX64,
        uint128 maxUtilX64,
        uint128 maxRateX64
    ) internal pure {
        int128 betaWithOffset = betaX64 + int128(BETA_OFFSET);
        if (betaWithOffset < 0) {
            revert BetaOverflowsOffset(betaX64);
        }

        self.invAlphaX128 = invAlphaX128;
        self.betaX64 = uint128(betaWithOffset);
        self.maxUtilX64 = maxUtilX64;
        self.maxRateX64 = maxRateX64;

        SmoothRateCurveLib.validate(self);
    }

    /// @notice Validates config passes safety checks.
    function validate(SmoothRateCurveConfig memory self) internal pure {
        if (self.invAlphaX128 == 0) {
            revert InvAlphaIsZero();
        }
        if (self.maxUtilX64 == 0) {
            revert MaxUtilIsZero();
        }
        if (self.maxRateX64 == 0) {
            revert MaxRateIsZero();
        }

        // verify overflow does not occur at extremes
        SmoothRateCurveLib.calculateRateX64(self, 0);
        uint128 maxCalculatedRate = SmoothRateCurveLib.calculateRateX64(self, self.maxUtilX64 - 1);
        if (self.maxRateX64 > maxCalculatedRate) {
            revert MaxRateAboveCurve(self.maxRateX64, maxCalculatedRate);
        }
    }

}
