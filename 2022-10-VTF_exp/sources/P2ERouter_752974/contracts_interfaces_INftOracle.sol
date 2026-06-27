// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

interface INftOracle {

    function values(uint256 nftId) external view returns (uint256);

    function valuesOf(address nftContract, uint256 nftId) external view returns (uint256);

}

