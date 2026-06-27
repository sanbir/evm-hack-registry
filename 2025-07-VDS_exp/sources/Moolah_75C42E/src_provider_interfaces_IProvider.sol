// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Id } from "moolah/interfaces/IMoolah.sol";

interface IProvider {
  function liquidate(Id id, address borrower) external;

  function TOKEN() external view returns (address);
}
