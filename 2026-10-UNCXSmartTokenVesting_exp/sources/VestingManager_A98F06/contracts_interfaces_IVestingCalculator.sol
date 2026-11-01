// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./IVesting.sol";

interface IVestingCalculator {
    enum EquationType {
        LINEAR,      // Linear release between points
        EXPONENTIAL, // Exponential curve between points
        INTERVAL,    // Immediate release at each point (same as STEPWISE)
        QUADRATIC    // Quadratic curve between points
    }

    struct TimeAmount {
        uint256 time;        // Unix timestamp
        uint256 amount;      // Cumulative amount of tokens until this time
        EquationType eqType; // Equation type for calculation until next point
    }
    
    error InvalidTranches();
    error TimesMustBeInAscendingOrder();
    error AmountsMustBeIncreasing();
    error InvalidEquationType();
    error InvalidParameters();
    error VestingTypeNotEnabled();

    function calculateVestedAmount(
        TimeAmount[] calldata tranches,
        uint256 currentTime
    ) external view returns (uint256);

    function getTotalAmount(TimeAmount[] calldata tranches) external pure returns (uint256);

}
