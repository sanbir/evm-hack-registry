// Website: https://barley.finance/
// Docs:  https://docs.barley.finance/
// Twitter: https://twitter.com/Barley_Finance
// Telegram Group: https://t.me/Barley_Finance
// Telegram Channel: https://t.me/BarleyFinance

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import './interfaces/IStakingPoolToken.sol';
import './TokenRewards.sol';

contract StakingPoolToken is IStakingPoolToken, ERC20 {
  using SafeERC20 for IERC20;

  address public override indexFund;
  address public override stakingToken;
  address public override poolRewards;
  address public override stakeUserRestriction;

  modifier onlyRestricted() {
    require(_msgSender() == stakeUserRestriction, 'RESUSERAUTH');
    _;
  }

  constructor(
    string memory _name,
    string memory _symbol,
    address _dai,
    address _stakingToken,
    address _rewardsToken,
    address _stakeUserRestriction,
    IV3TwapUtilities _v3TwapUtilities
  ) ERC20(_name, _symbol) {
    indexFund = _msgSender();
    stakingToken = _stakingToken;
    stakeUserRestriction = _stakeUserRestriction;
    poolRewards = address(
      new TokenRewards(_v3TwapUtilities, _dai, address(this), _rewardsToken)
    );
  }

  function stake(address _user, uint256 _amount) external override {
    if (stakeUserRestriction != address(0)) {
      require(_user == stakeUserRestriction, 'RESTRICT');
    }
    _mint(_user, _amount);
    IERC20(stakingToken).safeTransferFrom(_msgSender(), address(this), _amount);
    emit Stake(_msgSender(), _user, _amount);
  }

  function unstake(uint256 _amount) external override {
    _burn(_msgSender(), _amount);
    IERC20(stakingToken).safeTransfer(_msgSender(), _amount);
    emit Unstake(_msgSender(), _amount);
  }

  function removeStakeUserRestriction() external onlyRestricted {
    stakeUserRestriction = address(0);
  }

  function setStakeUserRestriction(address _user) external onlyRestricted {
    stakeUserRestriction = _user;
  }

  function _transfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal virtual override {
    super._transfer(_from, _to, _amount);
    _afterTokenTransfer(_from, _to, _amount);
  }

  function _mint(address _to, uint256 _amount) internal override {
    super._mint(_to, _amount);
    _afterTokenTransfer(address(0), _to, _amount);
  }

  function _burn(address _from, uint256 _amount) internal override {
    super._burn(_from, _amount);
    _afterTokenTransfer(_from, address(0), _amount);
  }

  function _afterTokenTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal {
    if (_from != address(0) && _from != address(0xdead)) {
      TokenRewards(poolRewards).setShares(_from, _amount, true);
    }
    if (_to != address(0) && _to != address(0xdead)) {
      TokenRewards(poolRewards).setShares(_to, _amount, false);
    }
  }
}
