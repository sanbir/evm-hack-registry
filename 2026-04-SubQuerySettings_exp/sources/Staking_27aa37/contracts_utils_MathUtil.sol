// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

library MathUtil {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? y : x;
    }

    function divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x - 1) / y + 1;
    }

    function mulDiv(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return (x * y) / z;
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x < y) {
            return 0;
        }
        return x - y;
    }

    function diffOrZero(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x > y) ? x - y : 0;
    }
}
