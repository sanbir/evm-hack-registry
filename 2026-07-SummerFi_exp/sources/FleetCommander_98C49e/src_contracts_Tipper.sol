// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITipper} from "../interfaces/ITipper.sol";
import {IERC20, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Constants} from "@summerfi/constants/Constants.sol";
import {PERCENTAGE_100, Percentage, toPercentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";
import {PercentageUtils} from "@summerfi/percentage-solidity/contracts/PercentageUtils.sol";

/**
 * @title Tipper
 * @notice Contract implementing tip accrual functionality
 * @dev This contract is designed to be inherited by ERC20-compliant contracts.
 *      It relies on the inheriting contract to implement ERC20 functionality,
 *      particularly the totalSupply() function.
 *
 * Important:
 * 1. The inheriting contract MUST be ERC20-compliant.
 * 2. The inheriting contract MUST implement the _mintTip function.
 * 3. The contract uses its own address as the token for calculations,
 *    assuming it represents shares in the system.
 * @custom:see ITipper
 */
abstract contract Tipper is ITipper {
    using PercentageUtils for uint256;

    /// @notice The maximum tip rate is 5%
    Percentage immutable MAX_TIP_RATE = Percentage.wrap(5 * 1e18);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The current tip rate (as Percentage)
    /// @dev Percentages have 18 decimals of precision
    Percentage public tipRate;

    /// @notice The timestamp of the last tip accrual
    uint256 public lastTipTimestamp;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Tipper contract
     * @param initialTipRate The initial tip rate for the Fleet
     */
    constructor(Percentage initialTipRate) {
        if (initialTipRate > MAX_TIP_RATE) {
            revert TipRateCannotExceedFivePercent();
        }
        tipRate = initialTipRate;
        lastTipTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Abstract function to mint new shares as tips
     * @dev This function is meant to be overridden by inheriting contracts.
     *      It is called internally by the _accrueTip function to mint new shares as tips.
     *      The implementation should create new shares for the specified account
     *      without requiring additional underlying assets.
     * @param account The address to receive the minted tip shares
     * @param amount The amount of shares to mint as a tip
     */
    function _mintTip(address account, uint256 amount) internal virtual;

    /**
     * @notice Sets a new tip rate
     * @dev Only callable by the FleetCommander. Accrues tips before changing the rate.
     * @param newTipRate The new tip rate to set, as a Percentage type (defined in @Percentage.sol)
     * @param tipJar The address of the tip jar
     * @param totalSupply The total supply of the shares
     * @custom:internal-logic
     * - Validates that the new tip rate is within the valid percentage range using @PercentageUtils.sol
     * - Accrues tips based on the current rate before updating
     * - Updates the tip rate to the new value
     * @custom:effects
     * - May mint new tip shares (via _accrueTip)
     * - Updates the tipRate state variable
     * @custom:security-considerations
     * - Ensures the new tip rate is within valid bounds (0-100%) using @PercentageUtils.isPercentageInRange
     * - Accrues tips before changing the rate to prevent loss of accrued tips
     * @custom:note The newTipRate should be sized according to the PERCENTAGE_FACTOR in @Percentage.sol.
     *              For example, 1% would be represented as 1 * 10^18 (assuming PERCENTAGE_DECIMALS is 18).
     */
    function _setTipRate(
        Percentage newTipRate,
        address tipJar,
        uint256 totalSupply
    ) internal {
        if (newTipRate > MAX_TIP_RATE) {
            revert TipRateCannotExceedFivePercent();
        }
        _accrueTip(tipJar, totalSupply); // Accrue tips before changing the rate
        tipRate = newTipRate;
        emit TipRateUpdated(newTipRate);
    }

    /**
     * @notice Previews the amount of tip that would be accrued if _accrueTip was called
     * @param tipJar The address of the tip jar
     * @param totalSupply The total supply of the shares
     * @return tippedShares The amount of tips that would be accrued in shares
     */
    function previewTip(
        address tipJar,
        uint256 totalSupply
    ) public view returns (uint256 tippedShares) {
        uint256 timeElapsed = block.timestamp - lastTipTimestamp;
        if (timeElapsed == 0) return 0;

        if (tipRate == toPercentage(0)) return 0;

        uint256 totalShares = totalSupply -
            IERC20(address(this)).balanceOf(tipJar);
        tippedShares = _calculateTip(totalShares, timeElapsed);
        return tippedShares;
    }

    /**
     * @notice Accrues tips based on the current tip rate and time elapsed
     * @dev Only callable by the FleetCommander
     * @param tipJar The address of the tip jar
     * @param totalSupply The total supply of the tip jar
     * @return tippedShares The amount of tips accrued in shares
     * @custom:internal-logic
     * - Calculates the time elapsed since the last tip accrual
     * - Computes the amount of new shares to mint based on the tip rate and time elapsed
     * - Mints new shares to the tip jar if the calculated amount is greater than zero
     * - Updates the lastTipTimestamp to the current block timestamp
     * @custom:effects
     * - May mint new tip shares (via _mintTip)
     * - Updates the lastTipTimestamp state variable
     * @custom:security-considerations
     * - Handles the case where tipRate is zero to prevent unnecessary computations
     * - Uses a custom power function for precise calculations
     */
    function _accrueTip(
        address tipJar,
        uint256 totalSupply
    ) internal returns (uint256 tippedShares) {
        if (tipRate == toPercentage(0)) {
            lastTipTimestamp = block.timestamp;
            return 0;
        }

        tippedShares = previewTip(tipJar, totalSupply);

        if (tippedShares > 0) {
            lastTipTimestamp = block.timestamp;
            _mintTip(tipJar, tippedShares);
            emit TipAccrued(tippedShares);
        }
    }

    /**
     * @notice Calculates the amount of tip to be accrued
     * @param totalShares The total number of shares in the system
     * @param timeElapsed The time elapsed since the last tip accrual
     * @return The amount of new shares to be minted as tip
     * @custom:internal-logic
     * - Calculates a time-adjusted rate by scaling the annual tip rate by the elapsed time
     * - Applies this adjusted rate to the total shares to determine tip amount
     * @custom:effects
     * - Does not modify any state, pure function
     */
    function _calculateTip(
        uint256 totalShares,
        uint256 timeElapsed
    ) internal view returns (uint256) {
        Percentage timeAdjustedRate = Percentage.wrap(
            ((timeElapsed * Percentage.unwrap(tipRate)) /
                Constants.SECONDS_PER_YEAR)
        );

        return totalShares.applyPercentage(timeAdjustedRate);
    }
}
