// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICollateralpool{
    function userProvideLiquidity(address to, uint amount1) external;
    function collat_XSD() external returns(uint);
    function collatDollarBalance() external view returns (uint256);
}

