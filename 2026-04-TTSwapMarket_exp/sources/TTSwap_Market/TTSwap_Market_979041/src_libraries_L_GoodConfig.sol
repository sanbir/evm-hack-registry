// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title L_GoodConfigLibrary
/// @notice A library for managing and retrieving configuration data for goods.
/// @dev This library uses bitwise operations and assembly for efficient storage and retrieval of configuration data.
/// The configuration is packed into a single `uint256` slot to save gas.
///
/// Configuration Layout (Bit ranges are approximate and illustrative based on bitwise shifts):
/// - Bit 255: isValueGood (1 = Value Good, 0 = Normal Good)
/// - Bit 254: isFreeze (1 = Frozen, 0 = Active)
/// - Bits 253-224: Various fee configurations (Liquidity, Operator, Gate, Referral, Customer, Platform)
/// - Bits 223: isApply (1 = Application enabled)
/// - Bits [63...]: Power factor (Leverage/Multiplier)
library L_GoodConfigLibrary {
    /// @notice Checks if the good is configured as a value good.
    /// @param config The configuration value.
    /// @return a True if it's a value good, false otherwise.
    function isvaluegood(uint256 config) internal pure returns (bool a) {
        return (config & (1 << 255)) != 0;
    }

    /// @notice Checks if the good is configured as a normal good.
    /// @param config The configuration value.
    /// @return a True if it's a normal good, false otherwise.
    function isnormalgood(uint256 config) internal pure returns (bool a) {
        return (config & (1 << 255)) == 0;
    }

    /// @notice Checks if the good is frozen (trading paused).
    /// @param config The configuration value.
    /// @return a True if the good is frozen, false otherwise.
    function isFreeze(uint256 config) internal pure returns (bool a) {
        return (config & (1 << 254)) != 0;
    }

    /// @notice Calculates the liquidity provider fee.
    /// @dev Extracts fee percentage from config bits [253...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated liquidity fee.
    function getLiquidFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(253, shl(2, config))
                config := mul(config, amount)
                a := div(config, 10)
            }
        }
    }

    /// @notice Calculates the operator fee (e.g. for market makers or admins).
    /// @dev Extracts fee percentage from config bits [252...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated operator fee.
    function getOperatorFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(252, shl(5, config))
                config := mul(config, amount)
                a := div(config, 50)
            }
        }
    }

    /// @notice Calculates the gate fee (e.g. for listing or access).
    /// @dev Extracts fee percentage from config bits [253...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated gate fee.
    function getGateFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(253, shl(9, config))
                config := mul(config, amount)
                a := div(config, 25)
            }
        }
    }

    /// @notice Calculates the referral fee.
    /// @dev Extracts fee percentage from config bits [251...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated referral fee.
    function getReferFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(251, shl(12, config))
                config := mul(config, amount)
                a := div(config, 100)
            }
        }
    }

    /// @notice Calculates the customer fee (e.g. cashback or discounts).
    /// @dev Extracts fee percentage from config bits [251...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated customer fee.
    function getCustomerFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(251, shl(17, config))
                config := mul(config, amount)
                a := div(config, 100)
            }
        }
    }

    /// @notice Calculates the platform fee (returned as uint128).
    /// @dev Extracts fee percentage from config bits [251...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated platform fee (uint128).
    function getPlatformFee128(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(251, shl(22, config))
                config := mul(config, amount)
                a := div(config, 100)
            }
        }
    }

    /// @notice Calculates the platform fee (returned as uint256).
    /// @dev Extracts fee percentage from config bits [251...] and applies it to amount.
    /// @param config The configuration value.
    /// @param amount The transaction amount.
    /// @return a The calculated platform fee (uint256).
    function getPlatformFee256(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint256 a) {
        unchecked {
            assembly {
                config := shr(251, shl(22, config))
                config := mul(config, amount)
                a := div(config, 100)
            }
        }
    }

    /// @notice Retrieves the power factor (leverage/multiplier) from the configuration.
    /// @dev Extracts the power value from config bits [251...]. Defaults to 1 if 0.
    /// @param config The configuration value.
    /// @return a The power factor.
    function getLimitPower(uint256 config) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                a := shr(251, shl(27, config))
            }
            if (a == 0) {
                a = 100;
            } else {
                a = a * 100;
            }
        }
    }

    /// @notice Checks if the configuration has the "Apply" flag set.
    /// @param config The configuration value.
    /// @return a True if the apply flag is set, false otherwise.
    function getApply(uint256 config) internal pure returns (bool a) {
        return (config & (1 << 223)) > 0;
    }

    /// @notice Calculate the investment fee for a given amount
    /// @param config The configuration value
    /// @param amount The investment amount
    /// @return a The calculated investment fee
    function getInvestFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(250, shl(33, config))
                config := mul(config, amount)
                a := div(config, 10000)
            }
        }
    }

    /// @notice Calculate the full investment quantity (before fee deduction).
    /// @dev This is the inverse of fee calculation, used when determining how much initial input is needed to yield a target output amount after fees.
    /// @param config The configuration value.
    /// @param amount The target investment amount (net of fees).
    /// @return a The gross investment amount required.
    function getInvestFullFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(250, shl(33, config))
                a := div(mul(amount, 10000), sub(10000, config))
            }
        }
    }

    /// @notice Calculate the disinvestment fee for a given amount
    /// @param config The configuration value
    /// @param amount The disinvestment amount
    /// @return a The calculated disinvestment fee
    function getDisinvestFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(250, shl(39, config))
                config := mul(config, amount)
                a := div(config, 10000)
            }
        }
    }

    /// @notice Calculate the buying fee for a given amount
    /// @param config The configuration value
    /// @param amount The buying amount
    /// @return a The calculated buying fee
    function getBuyFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(249, shl(45, config))
                config := mul(config, amount)
                a := div(config, 10000)
            }
        }
    }

    /// @notice Calculate the selling fee for a given amount
    /// @param config The configuration value
    /// @param amount The selling amount
    /// @return a The calculated selling fee
    function getSellFee(
        uint256 config,
        uint256 amount
    ) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                config := shr(249, shl(52, config))
                config := mul(config, amount)
                a := div(config, 10000)
            }
        }
    }

    /// @notice Get the swap chips for a given amount
    /// @param config The configuration value
    /// @return a The swap chips for the given amount
    function getPower(uint256 config) internal pure returns (uint128 a) {
        unchecked {
            assembly {
                a := shr(251, shl(64, config))
            }
        }
        return a == 0 ? 100 : 100 * a;
    }

    /// @notice Get the swap chips for a given amount

    /// @notice Get the disinvestment chips for a given amount
    /// @param config The configuration value
    /// @param amount The amount
    /// @return The disinvestment chips for the given amount
    function getDisinvestChips(
        uint256 config,
        uint128 amount
    ) internal pure returns (uint128) {
        uint128 a;
        assembly {
            a := shr(246, shl(69, config))
        }
        if (a == 0) return amount;
        return (amount / a);
    }

    function getK1(uint256 config) internal pure returns (uint128 a) {
        assembly {
            a := shr(240, shl(79, config))
        }
        return a == 0 ? 20000 : a * 10;
    }

    function getK2(uint256 config) internal pure returns (uint128 a) {
        assembly {
            a := shr(240, shl(79, config))
        }
        a = a == 0 ? 20000 : a * 10;
        a = (a * 10000) / (a - 10000);
        return a;
    }
    /// @notice Validates if a configuration value is well-formed and consistent.
    /// @dev Checks that the sum of all fee components (liquidity, operator, gate, referal, customer, platform) equals 100%.
    /// Each component is extracted from specific bit ranges and normalized.
    /// - Liquid: [251..253] * 10
    /// - Operator: [247..249] * 2
    /// - Gate: [244..246] * 4
    /// - Referral: [239..243]
    /// - Customer: [234..238]
    /// - Platform: [229..233]
    /// @param config The configuration value to check.
    /// @return result True if the configuration is valid (sum == 100 and no component is 0), false otherwise.
    function checkGoodConfig(
        uint256 config
    ) internal pure returns (bool result) {
        uint256 liquid;
        uint256 operator;
        uint256 gate;
        uint256 referal;
        uint256 cust;
        uint256 platform;

        assembly {
            // liquid = ((config >> 251) & 0x7) * 10
            liquid := mul(and(shr(251, config), 0x7), 10)
            // operator = ((config >> 247) & 0x7) * 2
            operator := mul(and(shr(247, config), 0x7), 2)
            // gate = ((config >> 244) & 0x7) * 4
            gate := mul(and(shr(244, config), 0x7), 4)
            // referal = (config >> 239) & 0x1F
            referal := and(shr(239, config), 0x1F)
            // cust = (config >> 234) & 0x1F
            cust := and(shr(234, config), 0x1F)
            // platform = (config >> 229) & 0x1F
            platform := and(shr(229, config), 0x1F)
        }

        // Check all components are non-zero and sum equals 100
        if (
            liquid == 0 ||
            operator == 0 ||
            gate == 0 ||
            referal == 0 ||
            cust == 0 ||
            platform == 0
        ) return false;

        return (liquid + operator + gate + referal + cust + platform == 100);
    }
}
