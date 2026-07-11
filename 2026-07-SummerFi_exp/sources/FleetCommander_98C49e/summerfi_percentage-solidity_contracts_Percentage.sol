// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title Percentage
 * @author Roberto Cano
 * @notice Custom type for Percentage values with associated utility functions
 * @dev This contract defines a custom Percentage type and overloaded operators
 *      to perform arithmetic and comparison operations on Percentage values.
 */

/**
 * @dev Custom percentage type as uint256
 * @notice This type is used to represent percentage values with high precision
 */
type Percentage is uint256;

/**
 * @dev Overridden operators declaration for Percentage
 * @notice These operators allow for intuitive arithmetic and comparison operations
 *         on Percentage values
 */
using {
    add as +,
    subtract as -,
    multiply as *,
    divide as /,
    lessOrEqualThan as <=,
    lessThan as <,
    greaterOrEqualThan as >=,
    greaterThan as >,
    equalTo as ==
} for Percentage global;

/**
 * @dev The number of decimals used for the percentage
 *  This constant defines the precision of the Percentage type
 */
uint256 constant PERCENTAGE_DECIMALS = 18;

/**
 * @dev The factor used to scale the percentage
 *  This constant is used to convert between human-readable percentages
 *         and the internal representation
 */
uint256 constant PERCENTAGE_FACTOR = 10 ** PERCENTAGE_DECIMALS;

/**
 * @dev Percentage of 100% with the given `PERCENTAGE_DECIMALS`
 *  This constant represents 100% in the Percentage type
 */
Percentage constant PERCENTAGE_100 = Percentage.wrap(100 * PERCENTAGE_FACTOR);

/**
 * OPERATOR FUNCTIONS
 */

/**
 * @dev Adds two Percentage values
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return The sum of a and b as a Percentage
 */
function add(Percentage a, Percentage b) pure returns (Percentage) {
    return Percentage.wrap(Percentage.unwrap(a) + Percentage.unwrap(b));
}

/**
 * @dev Subtracts one Percentage value from another
 * @param a The Percentage value to subtract from
 * @param b The Percentage value to subtract
 * @return The difference between a and b as a Percentage
 */
function subtract(Percentage a, Percentage b) pure returns (Percentage) {
    return Percentage.wrap(Percentage.unwrap(a) - Percentage.unwrap(b));
}

/**
 * @dev Multiplies two Percentage values
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return The product of a and b as a Percentage, scaled appropriately
 */
function multiply(Percentage a, Percentage b) pure returns (Percentage) {
    return
        Percentage.wrap(
            (Percentage.unwrap(a) * Percentage.unwrap(b)) /
                Percentage.unwrap(PERCENTAGE_100)
        );
}

/**
 * @dev Divides one Percentage value by another
 * @param a The Percentage value to divide
 * @param b The Percentage value to divide by
 * @return The quotient of a divided by b as a Percentage, scaled appropriately
 */
function divide(Percentage a, Percentage b) pure returns (Percentage) {
    return
        Percentage.wrap(
            (Percentage.unwrap(a) * Percentage.unwrap(PERCENTAGE_100)) /
                Percentage.unwrap(b)
        );
}

/**
 * @dev Checks if one Percentage value is less than or equal to another
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is less than or equal to b, false otherwise
 */
function lessOrEqualThan(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) <= Percentage.unwrap(b);
}

/**
 * @dev Checks if one Percentage value is less than another
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is less than b, false otherwise
 */
function lessThan(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) < Percentage.unwrap(b);
}

/**
 * @dev Checks if one Percentage value is greater than or equal to another
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is greater than or equal to b, false otherwise
 */
function greaterOrEqualThan(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) >= Percentage.unwrap(b);
}

/**
 * @dev Checks if one Percentage value is greater than another
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is greater than b, false otherwise
 */
function greaterThan(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) > Percentage.unwrap(b);
}

/**
 * @dev Checks if two Percentage values are equal
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is equal to b, false otherwise
 */
function equalTo(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) == Percentage.unwrap(b);
}

/**
 * @dev Alias for equalTo function
 * @param a The first Percentage value
 * @param b The second Percentage value
 * @return True if a is equal to b, false otherwise
 */
function equals(Percentage a, Percentage b) pure returns (bool) {
    return Percentage.unwrap(a) == Percentage.unwrap(b);
}

/**
 * @dev Converts a uint256 value to a Percentage
 * @param value The uint256 value to convert
 * @return The input value as a Percentage
 */
function toPercentage(uint256 value) pure returns (Percentage) {
    return Percentage.wrap(value * PERCENTAGE_FACTOR);
}

/**
 * @dev Converts a Percentage value to a uint256
 * @param value The Percentage value to convert
 * @return The Percentage value as a uint256
 */
function fromPercentage(Percentage value) pure returns (uint256) {
    return Percentage.unwrap(value) / PERCENTAGE_FACTOR;
}
