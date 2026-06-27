// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface I314Swap {
    function getAmountOutForToken(
        uint256 value,
        address outToken
    ) external view returns (uint256);

    error Unsafe314Swaper(address token);

    function on314Swaper() external pure returns (bytes4);
}
