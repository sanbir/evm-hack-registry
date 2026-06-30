// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IBIFKN314CALLEE {
    function BIFKN314CALL(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
