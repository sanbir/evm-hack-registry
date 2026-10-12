// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "../StabilityPod/PoolCollateral.sol";

interface IGlobalImpliedCollateralService {
  function sync(PoolCollateral memory) external;

  function syncArbTokens(address, uint256) external;

  function totalPhantomMalt() external view returns (uint256);

  function totalCollateral() external view returns (uint256);

  function totalSwingTraderCollateral() external view returns (uint256);

  function totalSwingTraderMalt() external view returns (uint256);

  function totalArbTokens() external view returns (uint256);

  function collateralRatio() external view returns (uint256);

  function swingTraderCollateralRatio() external view returns (uint256);

  function swingTraderCollateralDeficit() external view returns (uint256);

  function setPoolUpdater(address, address) external;

  function proposeNewUpdaterManager(address) external;

  function acceptUpdaterManagerRole() external;
}
