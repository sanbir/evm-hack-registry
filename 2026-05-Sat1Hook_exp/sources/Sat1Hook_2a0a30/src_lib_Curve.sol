// SPDX-License-Identifier: MIT
// https://www.sat1.io/
pragma solidity 0.8.26;

import {UD60x18, ud, exp, ln} from "@prb/math/src/UD60x18.sol";

/// @title Curve
/// @notice Bonding-curve math for sat1.
/// @dev Forward curve: totalMinted(eth) = K * (1 - e^{-eth / S})
///      Inverse curve: eth(total) = -S * ln(1 - total / K)
///      `S` is calibrated so 99% of the curve is reached at about 1361 ETH.
library Curve {
    /// @notice Total cap on supply. Asymptote of the forward curve.
    uint256 internal constant K_SUPPLY = 21_000_000e18;

    /// @notice Curve scale. S * ln(100) ~= 1361 ETH, so 99% self-deprecation lands there.
    uint256 internal constant S = 295_537_394_935_162_868_716;

    /// @notice Maximum eth/S value at which the curve is treated as fully exhausted.
    uint256 internal constant MAX_EXP_X = 50e18;

    error SellExceedsSupply();
    error InverseDomainError();

    /// @notice Cumulative tokens minted after `eth` total ETH has been spent into the curve.
    function totalMinted(uint256 eth) internal pure returns (uint256) {
        if (eth == 0) return 0;

        UD60x18 x = _div(ud(eth), ud(S));
        if (x.unwrap() >= MAX_EXP_X) return K_SUPPLY;

        UD60x18 expPos = exp(x);
        UD60x18 invExp = _div(ud(1e18), expPos);
        UD60x18 oneMinus = _sub(ud(1e18), invExp);
        return _mul(ud(K_SUPPLY), oneMinus).unwrap();
    }

    /// @notice SATO-style mint delta for a buy of `eth` on top of `ethBefore`.
    function mintFor(uint256 ethBefore, uint256 eth) internal pure returns (uint256) {
        if (eth == 0) return 0;
        uint256 a = totalMinted(ethBefore);
        uint256 b = totalMinted(ethBefore + eth);
        return b > a ? b - a : 0;
    }

    /// @notice Marginal ETH per sat1 at curve position `eth`.
    function marginalPrice(uint256 eth) internal pure returns (uint256) {
        UD60x18 x = _div(ud(eth), ud(S));
        UD60x18 expPos = x.unwrap() >= MAX_EXP_X ? exp(ud(MAX_EXP_X)) : exp(x);
        return _div(_mul(ud(S), expPos), ud(K_SUPPLY)).unwrap();
    }

    /// @notice ETH owed to a seller burning `satoIn` fair-curve units at current fair supply.
    function burnFor(uint256 currentTotal, uint256 satoIn) internal pure returns (uint256) {
        if (satoIn == 0) return 0;
        if (satoIn > currentTotal) revert SellExceedsSupply();

        uint256 denomU = K_SUPPLY - currentTotal;
        if (denomU == 0) revert InverseDomainError();

        uint256 numU = denomU + satoIn;
        UD60x18 ratio = _div(ud(numU), ud(denomU));
        return _mul(ud(S), ln(ratio)).unwrap();
    }

    /// @notice ETH that maps to a fair-curve circulating supply.
    function ethAt(uint256 currentTotal) internal pure returns (uint256) {
        if (currentTotal == 0) return 0;
        if (currentTotal >= K_SUPPLY) revert InverseDomainError();

        UD60x18 ratio = _div(ud(K_SUPPLY), ud(K_SUPPLY - currentTotal));
        return _mul(ud(S), ln(ratio)).unwrap();
    }

    function _sub(UD60x18 a, UD60x18 b) private pure returns (UD60x18) {
        return UD60x18.wrap(a.unwrap() - b.unwrap());
    }

    function _mul(UD60x18 a, UD60x18 b) private pure returns (UD60x18) {
        return UD60x18.wrap((a.unwrap() * b.unwrap()) / 1e18);
    }

    function _div(UD60x18 a, UD60x18 b) private pure returns (UD60x18) {
        return UD60x18.wrap((a.unwrap() * 1e18) / b.unwrap());
    }
}
