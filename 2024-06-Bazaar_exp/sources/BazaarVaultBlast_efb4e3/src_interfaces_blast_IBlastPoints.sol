// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IBlastPoints {
  function configurePointsOperator(address operator) external;
  function configurePointsOperatorOnBehalf(address contractAddress, address operator) external;
}