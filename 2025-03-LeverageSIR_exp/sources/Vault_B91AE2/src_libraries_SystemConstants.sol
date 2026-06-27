// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SystemConstants {
    uint8 internal constant SIR_DECIMALS = 12;

    /** SIR Token Issuance Rate
        If we want to issue 2,015,000,000 SIR per year, this implies an issuance rate of 63.9 SIR/s.
     */
    uint72 internal constant ISSUANCE = uint72(2015e6 * 10 ** SIR_DECIMALS - 1) / 365 days + 1; // [sir/s]

    /** During the first 3 years, 30%-to-33% of the emissions are diverged to contributors.
        - 10% to pre-mainnet contributors
        - 10%-13% to fundraising contributors
        - 10% to a treasury for post-mainnet stuff
     */
    uint72 internal constant LP_ISSUANCE_FIRST_3_YEARS = uint72((uint256(68126421999999980) * ISSUANCE) / 1e17);

    uint128 internal constant TEA_MAX_SUPPLY = (uint128(LP_ISSUANCE_FIRST_3_YEARS) << 96) / type(uint16).max; // Must fit in uint128

    uint40 internal constant THREE_YEARS = 3 * 365 days;

    int64 internal constant MAX_TICK_X42 = 1951133415219145403; // log_1.0001((2^128-1(/2^64))*2^42

    // Approximately 10 days. We did not choose 10 days precisely to avoid auctions always ending on the same day and time of the week.
    uint40 internal constant AUCTION_COOLDOWN = 247 hours; // 247h & 240h have no common factors

    // Duration of an auction
    uint40 internal constant AUCTION_DURATION = 24 hours;

    // Time it takes for a change of LP or base fee to take effect
    uint256 internal constant FEE_CHANGE_DELAY = 10 days;

    uint40 internal constant SHUTDOWN_WITHDRAWAL_DELAY = 20 days;

    int8 internal constant MAX_LEVERAGE_TIER = 2;

    int8 internal constant MIN_LEVERAGE_TIER = -4;

    uint256 internal constant HALVING_PERIOD = 30 days; // Every 30 days, half of the locked stake is unlocked
}
