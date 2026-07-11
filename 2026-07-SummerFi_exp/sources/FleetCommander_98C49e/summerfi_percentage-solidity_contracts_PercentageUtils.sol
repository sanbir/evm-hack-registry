// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PERCENTAGE_100, PERCENTAGE_FACTOR, Percentage, toPercentage} from "./Percentage.sol";

/**
 * @title PercentageUtils
 * @author Roberto Cano
 * @notice Utility library to apply percentage calculations to input amounts
 * @dev This library provides functions for adding, subtracting, and applying
 *      percentages to amounts, as well as utility functions for working with
 *      percentages.
 */
library PercentageUtils {
    /**
     * @notice Adds the percentage to the given amount and returns the result
     * @param amount The base amount to which the percentage will be added
     * @param percentage The percentage to add to the amount
     * @return The amount after the percentage is applied
     * @dev It performs the following operation: (100.0% + percentage) * amount
     */
    function addPercentage(
        uint256 amount,
        Percentage percentage
    ) internal pure returns (uint256) {
        return applyPercentage(amount, PERCENTAGE_100 + percentage);
    }

    /**
     * @notice Subtracts the percentage from the given amount and returns the result
     * @param amount The base amount from which the percentage will be subtracted
     * @param percentage The percentage to subtract from the amount
     * @return The amount after the percentage is applied
     * @dev It performs the following operation: (100.0% - percentage) * amount
     */
    function subtractPercentage(
        uint256 amount,
        Percentage percentage
    ) internal pure returns (uint256) {
        return applyPercentage(amount, PERCENTAGE_100 - percentage);
    }

    /**
     * @notice Applies the given percentage to the given amount and returns the result
     * @param amount The amount to apply the percentage to
     * @param percentage The percentage to apply to the amount
     * @return The amount after the percentage is applied
     * @dev This function is used internally by addPercentage and subtractPercentage
     */
    function applyPercentage(
        uint256 amount,
        Percentage percentage
    ) internal pure returns (uint256) {
        return
            (amount * Percentage.unwrap(percentage)) /
            Percentage.unwrap(PERCENTAGE_100);
    }

    /**
     * @notice Checks if the given percentage is in range, this is, if it is between 0 and 100
     * @param percentage The percentage to check
     * @return True if the percentage is in range, false otherwise
     * @dev This function is useful for validating input percentages
     */
    function isPercentageInRange(
        Percentage percentage
    ) internal pure returns (bool) {
        return percentage <= PERCENTAGE_100;
    }

    /**
     * @notice Converts the given fraction into a percentage with the right number of decimals
     * @param numerator The numerator of the fraction
     * @param denominator The denominator of the fraction
     * @return The percentage with `PERCENTAGE_DECIMALS` decimals
     * @dev This function is useful for converting ratios to percentages
     *     For example, fromFraction(1, 2) returns 50%
     */
    function fromFraction(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (Percentage) {
        return
            Percentage.wrap(
                (numerator * PERCENTAGE_FACTOR * 100) / denominator
            );
    }

    /**
     * @notice Converts the given integer into a percentage
     * @param percentage The percentage in human-readable format, i.e., 50 for 50%
     * @return The percentage with `PERCENTAGE_DECIMALS` decimals
     * @dev This function is useful for converting human-readable percentages to the internal representation
     */
    function fromIntegerPercentage(
        uint256 percentage
    ) internal pure returns (Percentage) {
        return toPercentage(percentage);
    }
}
