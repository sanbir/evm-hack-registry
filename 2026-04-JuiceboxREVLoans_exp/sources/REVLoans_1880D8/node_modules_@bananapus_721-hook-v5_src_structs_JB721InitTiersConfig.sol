// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPrices} from "@bananapus/core-v5/src/interfaces/IJBPrices.sol";

import {JB721TierConfig} from "./JB721TierConfig.sol";

/// @notice Config to initialize a `JB721TiersHook` with tiers and price data.
/// @dev The `tiers` must be sorted by price (from least to greatest).
/// @custom:member tiers The tiers to initialize the hook with.
/// @custom:member currency The currency that the tier prices are denoted in. See `JBPrices`.
/// @custom:member decimals The number of decimals in the fixed point tier prices.
/// @custom:member prices A contract that exposes price feeds that can be used to calculate prices in different
/// currencies. To only accept payments in `currency`, set `prices` to the zero address. See `JBPrices`.
struct JB721InitTiersConfig {
    JB721TierConfig[] tiers;
    uint32 currency;
    uint8 decimals;
    IJBPrices prices;
}
