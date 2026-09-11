// SPDX-License-Identifier: RECONSTRUCTED
pragma solidity ^0.5.16;

/**
 * RECONSTRUCTED teaching stub for Tectonic's internal price oracle
 * (0xD360D8cABc1b2e56eCf348BFF00D2Bd9F658754A on Cronos).
 * Cronos verified source is not fetchable via Etherscan V2; behaviour confirmed
 * on-fork: getUnderlyingPrice(tTONIC) == TONIC/USD feed answer scaled to 1e18.
 * TONIC/USD feed (0x14f753…) is documented as sourced from VVS Finance + Crypto.com.
 */
interface AggregatorInterface {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

contract PriceOracle {
    mapping(address => address) public feeds; // tToken => feed

    // VULN: returns whatever the (spot/CEX-hybrid) feed says — no TWAP,
    // deviation bound, or thin-liquidity circuit breaker for TONIC.
    function getUnderlyingPrice(address tToken) public view returns (uint256) {
        address feed = feeds[tToken];
        require(feed != address(0), "no feed");
        int256 answer = AggregatorInterface(feed).latestAnswer();
        require(answer > 0, "price <= 0");
        uint8 feedDecimals = AggregatorInterface(feed).decimals(); // TONIC/USD = 12
        // Scale to 1e18 USD-per-whole-token (Compound convention for 18-dec underlying)
        return uint256(answer) * (10 ** (18 - feedDecimals)); // line ~42 — vulnerable path
    }
}
