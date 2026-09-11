// SPDX-License-Identifier: RECONSTRUCTED
pragma solidity ^0.5.16;

interface PriceOracle {
    function getUnderlyingPrice(address tToken) external view returns (uint);
}

/**
 * RECONSTRUCTED teaching stub for TectonicSocket
 * (0xb3831584acb95ED9cCb0C11f677B5AD01DeaeEc0).
 * Compound-fork account-liquidity check: collateral value = tToken bal * exchangeRate
 * * oracle.getUnderlyingPrice(tToken) * collateralFactor.
 */
contract Comptroller {
    PriceOracle public oracle;
    struct Market {
        bool isListed;
        uint collateralFactorMantissa; // tTONIC = 0.2e18
        bool isComped;
    }
    mapping(address => Market) public markets;

    // Borrow gate: liquidity from (possibly manipulated) oracle prices.
    function borrowAllowed(address tToken, address borrower, uint borrowAmount) external returns (uint) {
        // ... enter-market / pause checks omitted ...
        (uint err, uint liquidity, uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != 0) return err;
        if (shortfall > 0) return 3; // insufficient liquidity
        // liquidity already priced with oracle.getUnderlyingPrice(tTONIC) — line ~88
        return 0;
    }

    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        return getAccountLiquidityInternal(account);
    }

    function getAccountLiquidityInternal(address account) internal view returns (uint, uint, uint) {
        // For each collateral tToken: sum(bal * cf * oracle.getUnderlyingPrice(tToken) / 1e18)
        // minus borrowed value. Inflated TONIC price → inflated liquidity → over-borrow.
        uint price = oracle.getUnderlyingPrice(/* tTONIC */); // line ~105 — uses spot feed
        price; account;
        return (0, 0, 0);
    }
}
