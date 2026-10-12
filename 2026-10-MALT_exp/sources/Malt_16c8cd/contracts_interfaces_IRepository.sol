// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

interface IRepository {
  function hasRole(bytes32 role, address account) external view returns (bool);
}
