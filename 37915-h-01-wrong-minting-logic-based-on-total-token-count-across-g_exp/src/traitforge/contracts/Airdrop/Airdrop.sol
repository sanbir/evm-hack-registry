// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import './IAirdrop.sol';

contract Airdrop is IAirdrop, Ownable, ReentrancyGuard, Pausable {
  bool private started;
  bool private daoAllowed;

  IERC20 public traitToken;
  uint256 public totalTokenAmount;
  uint256 public totalValue;

  mapping(address => uint256) public userInfo;

  function setTraitToken(address _traitToken) external onlyOwner {
    traitToken = IERC20(_traitToken);
  }

  function startAirdrop(
    uint256 amount
  ) external whenNotPaused nonReentrant onlyOwner {
    require(!started, 'Already started');
    require(amount > 0, 'Invalid amount');
    traitToken.transferFrom(tx.origin, address(this), amount);
    started = true;
    totalTokenAmount = amount;
  }

  function airdropStarted() external view returns (bool) {
    return started;
  }

  function allowDaoFund() external onlyOwner {
    require(started, 'Not started');
    require(!daoAllowed, 'Already allowed');
    daoAllowed = true;
  }

  function daoFundAllowed() external view returns (bool) {
    return daoAllowed;
  }

  function addUserAmount(
    address user,
    uint256 amount
  ) external whenNotPaused nonReentrant onlyOwner {
    require(!started, 'Already started');
    userInfo[user] += amount;
    totalValue += amount;
  }

  function subUserAmount(
    address user,
    uint256 amount
  ) external whenNotPaused nonReentrant onlyOwner {
    require(!started, 'Already started');
    require(userInfo[user] >= amount, 'Invalid amount');
    userInfo[user] -= amount;
    totalValue -= amount;
  }

  function claim() external whenNotPaused nonReentrant {
    require(started, 'Not started');
    require(userInfo[msg.sender] > 0, 'Not eligible');

    uint256 amount = (totalTokenAmount * userInfo[msg.sender]) / totalValue;
    traitToken.transfer(msg.sender, amount);
    userInfo[msg.sender] = 0;
  }
}
