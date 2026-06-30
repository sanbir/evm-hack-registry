// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ATMLibrary — Pure computation helpers for ATMToken
 * @notice Deployed separately, called via delegatecall. No state variables.
 */
library ATMLibrary {
    // P0 allocation ratios (basis points /10000)
    uint256 internal constant R_P1 = 40;    // 0.4%
    uint256 internal constant R_P2 = 1000;  // 10%
    uint256 internal constant R_P3 = 30;    // 0.3%
    uint256 internal constant R_P5 = 250;   // 2.5% — 参与出局且持币≥100U的用户永久分红
    uint256 internal constant R_P6 = 8080;  // 80.8%
    uint256 internal constant R_P8 = 500;   // 5%
    uint256 internal constant R_P9 = 100;   // 1% — 余数兜底
    // Total: 40+1000+30+250+8080+500+100 = 10000

    uint256 internal constant GAS_COEFF = 619; // 6.19% = 619/10000

    struct P0Allocation {
        uint256 toP1;
        uint256 toP2;
        uint256 toP3;
        uint256 toP5;
        uint256 toP6;
        uint256 toP8;
        uint256 toP9;
    }

    /// @notice Calculate P0 distribution amounts
    function calcP0Distribution(uint256 usdtAmount) internal pure returns (P0Allocation memory a) {
        a.toP1 = usdtAmount * R_P1 / 10000;
        a.toP2 = usdtAmount * R_P2 / 10000;
        a.toP3 = usdtAmount * R_P3 / 10000;
        a.toP5 = usdtAmount * R_P5 / 10000;
        a.toP6 = usdtAmount * R_P6 / 10000;
        a.toP8 = usdtAmount * R_P8 / 10000;
        // P9 gets remainder to avoid rounding dust
        a.toP9 = usdtAmount - a.toP1 - a.toP2 - a.toP3 - a.toP5 - a.toP6 - a.toP8;
    }

    /// @notice Calculate Gas deduction from P7 new income
    function calcGasDeduction(uint256 p7NewIncome) internal pure returns (uint256) {
        return p7NewIncome * GAS_COEFF / 10000;
    }

    /// @notice Calculate dormancy confiscation percentage
    /// @param lastSwapTime Last valid swap timestamp
    /// @param lastPercent Previously confiscated percentage  
    /// @param dormancyThreshold Time before dormancy kicks in (testnet: 300s)
    /// @param dormancyIncrement Time per additional 1% (testnet: 120s)
    /// @return deltaPercent Additional percentage to confiscate (0 if not dormant or already confiscated)
    function calcDormancyPercent(
        uint256 lastSwapTime,
        uint256 lastPercent,
        uint256 dormancyThreshold,
        uint256 dormancyIncrement
    ) internal view returns (uint256 deltaPercent) {
        if (lastSwapTime == 0) return 0;
        if (block.timestamp <= lastSwapTime + dormancyThreshold) return 0;
        
        uint256 overdue = block.timestamp - lastSwapTime - dormancyThreshold;
        // 1% base + 1% per increment
        uint256 totalPercent = 1 + overdue / dormancyIncrement;
        if (totalPercent > 100) totalPercent = 100;
        if (totalPercent <= lastPercent) return 0;
        deltaPercent = totalPercent - lastPercent;
    }

    /// @notice Calculate follow-sell amount (0.2X of user sell, capped by balance)
    function calcFollowSellAmount(uint256 userSellAmount, uint256 exitHoleBalance) internal pure returns (uint256) {
        uint256 target = userSellAmount / 5; // 0.2X
        return target > exitHoleBalance ? exitHoleBalance : target;
    }

    /// @notice Calculate P6→P7 release ratio based on time since last P0 release
    function calcP6ReleaseRatio(
        uint256 timeSinceLastRelease,
        uint256 accelThreshold,
        uint256 fullThreshold
    ) internal pure returns (uint256 numerator, uint256 denominator) {
        if (timeSinceLastRelease >= fullThreshold) {
            return (1, 1); // 100%
        } else if (timeSinceLastRelease >= accelThreshold + (fullThreshold - accelThreshold) * 2 / 3) {
            return (2, 3); // 2/3
        } else if (timeSinceLastRelease >= accelThreshold) {
            return (1, 2); // 1/2
        } else {
            return (1, 3); // 1/3 default
        }
    }

    /// @notice Calculate P0 threshold with decay
    function calcP0Threshold(uint256 decayLevel) internal pure returns (uint256) {
        if (decayLevel == 0) return 5e18;    // prod: 800e18
        if (decayLevel == 1) return 3e18;    // prod: 400e18
        if (decayLevel == 2) return 2e18;    // prod: 200e18
        return 1e18; // floor                // prod: 100e18
    }

    /// @notice Get USDT value of ATM amount using reserves
    function getUsdtValue(
        uint256 atmAmount,
        uint256 reserveATM,
        uint256 reserveUSDT
    ) internal pure returns (uint256) {
        if (reserveATM == 0) return 0;
        return atmAmount * reserveUSDT / reserveATM;
    }

    /// @notice Calculate min of two prices (TWAP vs spot)
    function minPrice(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Calculate TWAP price from cumulative data
    /// @return price USDT per ATM scaled 1e18, or 0 if no data
    function calcTwapPrice(
        uint256 cumulativePrice,
        uint256 accumulatedBlocks,
        bool ready,
        uint256 reserveATM,
        uint256 reserveUSDT
    ) internal pure returns (uint256) {
        if (ready && accumulatedBlocks > 0) {
            return cumulativePrice / accumulatedBlocks;
        }
        if (reserveATM == 0) return 0;
        return reserveUSDT * 1e18 / reserveATM;
    }

    /// @notice Calculate P3→P4 injection amount (3-tier adaptive)
    /// @param p3Balance Current P3 balance
    /// @param roundDurationMin Round duration in minutes
    /// @param timeSinceLastIncome Time since P3 last received P0 income
    /// @param accelTime Threshold for acceleration tier (testnet: 120s)
    /// @param dumpTime Threshold for freeze tier (testnet: 300s)
    /// @return amount to inject, isFrozen
    function calcP3Injection(
        uint256 p3Balance,
        uint256 roundDurationMin,
        uint256 timeSinceLastIncome,
        uint256 accelTime,
        uint256 dumpTime
    ) internal pure returns (uint256 amount, bool isFrozen) {
        if (timeSinceLastIncome >= dumpTime) {
            return (0, true); // frozen
        }
        
        if (timeSinceLastIncome >= accelTime) {
            // Acceleration: max(normal, 30%)
            uint256 normal = p3Balance * roundDurationMin / 360;
            uint256 floor = p3Balance * 30 / 100;
            amount = normal > floor ? normal : floor;
        } else {
            // Normal: duration/360
            amount = p3Balance * roundDurationMin / 360;
        }
        
        if (amount > p3Balance) amount = p3Balance;
        return (amount, false);
    }
}
