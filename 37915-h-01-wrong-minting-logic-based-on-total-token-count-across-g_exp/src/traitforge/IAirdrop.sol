// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAirdrop {
  function setTraitToken(address _traitToken) external;

  function startAirdrop(uint256 amount) external;

  function airdropStarted() external view returns (bool);

  function allowDaoFund() external;

  function daoFundAllowed() external view returns (bool);

  function addUserAmount(address user, uint256 amount) external;

  function subUserAmount(address user, uint256 amount) external;

  function claim() external;
}
