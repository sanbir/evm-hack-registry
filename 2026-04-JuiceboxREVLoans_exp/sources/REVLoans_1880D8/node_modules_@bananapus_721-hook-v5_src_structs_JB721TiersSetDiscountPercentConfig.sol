// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member tierId The ID of the tier to set the discount percent for.
/// @custom:member discountPercent The discount percent to set for the tier.
struct JB721TiersSetDiscountPercentConfig {
    uint32 tierId;
    uint16 discountPercent;
}
