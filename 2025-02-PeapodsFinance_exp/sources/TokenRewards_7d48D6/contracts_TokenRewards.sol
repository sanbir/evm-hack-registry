// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint96.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol';
import './interfaces/IDecentralizedIndex.sol';
import './interfaces/IPEAS.sol';
import './interfaces/IProtocolFees.sol';
import './interfaces/IProtocolFeeRouter.sol';
import './interfaces/ITokenRewards.sol';
import './interfaces/IV3TwapUtilities.sol';
import './interfaces/IUniswapV2Router02.sol';
import './libraries/BokkyPooBahsDateTimeLibrary.sol';
import './libraries/PoolAddress.sol';

contract TokenRewards is ITokenRewards, Context {
  using SafeERC20 for IERC20;

  address constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
  uint256 constant PRECISION = 10 ** 36;
  uint24 constant REWARDS_POOL_FEE = 10000; // 1%
  address immutable INDEX_FUND;
  address immutable PAIRED_LP_TOKEN;
  IProtocolFeeRouter immutable PROTOCOL_FEE_ROUTER;
  IV3TwapUtilities immutable V3_TWAP_UTILS;

  struct Reward {
    uint256 excluded;
    uint256 realized;
  }

  address public immutable override trackingToken;
  address public immutable override rewardsToken;
  uint256 public override totalShares;
  uint256 public override totalStakers;
  mapping(address => uint256) public shares;
  mapping(address => Reward) public rewards;

  uint256 _rewardsSwapSlippage = 10; // 1%
  uint256 _rewardsPerShare;
  uint256 public rewardsDistributed;
  uint256 public rewardsDeposited;
  mapping(uint256 => uint256) public rewardsDepMonthly;

  modifier onlyTrackingToken() {
    require(_msgSender() == trackingToken, 'UNAUTHORIZED');
    _;
  }

  constructor(
    IProtocolFeeRouter _feeRouter,
    IV3TwapUtilities _v3TwapUtilities,
    address _indexFund,
    address _pairedLpToken,
    address _trackingToken,
    address _rewardsToken
  ) {
    PROTOCOL_FEE_ROUTER = _feeRouter;
    V3_TWAP_UTILS = _v3TwapUtilities;
    INDEX_FUND = _indexFund;
    PAIRED_LP_TOKEN = _pairedLpToken;
    trackingToken = _trackingToken;
    rewardsToken = _rewardsToken;
  }

  function setShares(
    address _wallet,
    uint256 _amount,
    bool _sharesRemoving
  ) external override onlyTrackingToken {
    _setShares(_wallet, _amount, _sharesRemoving);
  }

  function _setShares(
    address _wallet,
    uint256 _amount,
    bool _sharesRemoving
  ) internal {
    _processFeesIfApplicable();
    if (_sharesRemoving) {
      _removeShares(_wallet, _amount);
      emit RemoveShares(_wallet, _amount);
    } else {
      _addShares(_wallet, _amount);
      emit AddShares(_wallet, _amount);
    }
  }

  function _addShares(address _wallet, uint256 _amount) internal {
    if (shares[_wallet] > 0) {
      _distributeReward(_wallet);
    }
    uint256 sharesBefore = shares[_wallet];
    totalShares += _amount;
    shares[_wallet] += _amount;
    if (sharesBefore == 0 && shares[_wallet] > 0) {
      totalStakers++;
    }
    rewards[_wallet].excluded = _cumulativeRewards(shares[_wallet]);
  }

  function _removeShares(address _wallet, uint256 _amount) internal {
    require(shares[_wallet] > 0 && _amount <= shares[_wallet], 'REMOVE');
    _distributeReward(_wallet);
    totalShares -= _amount;
    shares[_wallet] -= _amount;
    if (shares[_wallet] == 0) {
      totalStakers--;
    }
    rewards[_wallet].excluded = _cumulativeRewards(shares[_wallet]);
  }

  function _processFeesIfApplicable() internal {
    IDecentralizedIndex(INDEX_FUND).processPreSwapFeesAndSwap();
    if (
      rewardsToken != PAIRED_LP_TOKEN &&
      IERC20(PAIRED_LP_TOKEN).balanceOf(address(this)) > 0
    ) {
      depositFromPairedLpToken(0, 0);
    }
  }

  function depositFromPairedLpToken(
    uint256 _amountTknDepositing,
    uint256 _slippageOverride
  ) public override {
    require(PAIRED_LP_TOKEN != rewardsToken, 'LPREWSAME');
    if (_amountTknDepositing > 0) {
      IERC20(PAIRED_LP_TOKEN).safeTransferFrom(
        _msgSender(),
        address(this),
        _amountTknDepositing
      );
    }
    uint256 _amountTkn = IERC20(PAIRED_LP_TOKEN).balanceOf(address(this));
    require(_amountTkn > 0, 'NEEDTKN');
    uint256 _adminAmt;
    (uint256 _yieldAdminFee, ) = _getYieldFees();
    if (_yieldAdminFee > 0) {
      _adminAmt =
        (_amountTkn * _yieldAdminFee) /
        PROTOCOL_FEE_ROUTER.protocolFees().DEN();
      _amountTkn -= _adminAmt;
    }
    (address _token0, address _token1) = PAIRED_LP_TOKEN < rewardsToken
      ? (PAIRED_LP_TOKEN, rewardsToken)
      : (rewardsToken, PAIRED_LP_TOKEN);
    PoolAddress.PoolKey memory _poolKey = PoolAddress.PoolKey({
      token0: _token0,
      token1: _token1,
      fee: REWARDS_POOL_FEE
    });
    address _pool = PoolAddress.computeAddress(
      IPeripheryImmutableState(V3_ROUTER).factory(),
      _poolKey
    );
    uint160 _rewardsSqrtPriceX96 = V3_TWAP_UTILS
      .sqrtPriceX96FromPoolAndInterval(_pool);
    uint256 _rewardsPriceX96 = V3_TWAP_UTILS.priceX96FromSqrtPriceX96(
      _rewardsSqrtPriceX96
    );
    uint256 _amountOut = _token0 == PAIRED_LP_TOKEN
      ? (_rewardsPriceX96 * _amountTkn) / FixedPoint96.Q96
      : (_amountTkn * FixedPoint96.Q96) / _rewardsPriceX96;

    uint256 _rewardsBalBefore = IERC20(rewardsToken).balanceOf(address(this));
    IERC20(PAIRED_LP_TOKEN).safeIncreaseAllowance(V3_ROUTER, _amountTkn);
    uint256 _slippage = _slippageOverride > 0
      ? _slippageOverride
      : _rewardsSwapSlippage;
    try
      ISwapRouter(V3_ROUTER).exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
          tokenIn: PAIRED_LP_TOKEN,
          tokenOut: rewardsToken,
          fee: REWARDS_POOL_FEE,
          recipient: address(this),
          deadline: block.timestamp,
          amountIn: _amountTkn,
          amountOutMinimum: (_amountOut * (1000 - _slippage)) / 1000,
          sqrtPriceLimitX96: 0
        })
      )
    {
      if (_adminAmt > 0) {
        IERC20(PAIRED_LP_TOKEN).safeTransfer(
          Ownable(address(V3_TWAP_UTILS)).owner(),
          _adminAmt
        );
      }
      _rewardsSwapSlippage = 10;
      _depositRewards(
        IERC20(rewardsToken).balanceOf(address(this)) - _rewardsBalBefore
      );
    } catch {
      if (_rewardsSwapSlippage < 500) {
        _rewardsSwapSlippage += 10;
      }
      IERC20(PAIRED_LP_TOKEN).safeDecreaseAllowance(V3_ROUTER, _amountTkn);
    }
  }

  function depositRewards(uint256 _amount) external override {
    require(_amount > 0, 'DEPAM');
    uint256 _rewardsBalBefore = IERC20(rewardsToken).balanceOf(address(this));
    IERC20(rewardsToken).safeTransferFrom(_msgSender(), address(this), _amount);
    _depositRewards(
      IERC20(rewardsToken).balanceOf(address(this)) - _rewardsBalBefore
    );
  }

  function _depositRewards(uint256 _amountTotal) internal {
    if (_amountTotal == 0) {
      return;
    }
    if (totalShares == 0) {
      _burnRewards(_amountTotal);
      return;
    }

    uint256 _depositAmount = _amountTotal;
    (, uint256 _yieldBurnFee) = _getYieldFees();
    if (_yieldBurnFee > 0) {
      uint256 _burnAmount = (_amountTotal * _yieldBurnFee) /
        PROTOCOL_FEE_ROUTER.protocolFees().DEN();
      if (_burnAmount > 0) {
        _burnRewards(_burnAmount);
        _depositAmount -= _burnAmount;
      }
    }
    rewardsDeposited += _depositAmount;
    rewardsDepMonthly[beginningOfMonth(block.timestamp)] += _depositAmount;
    _rewardsPerShare += (PRECISION * _depositAmount) / totalShares;
    emit DepositRewards(_msgSender(), _depositAmount);
  }

  function _distributeReward(address _wallet) internal {
    if (shares[_wallet] == 0) {
      return;
    }
    uint256 _amount = getUnpaid(_wallet);
    rewards[_wallet].realized += _amount;
    rewards[_wallet].excluded = _cumulativeRewards(shares[_wallet]);
    if (_amount > 0) {
      rewardsDistributed += _amount;
      IERC20(rewardsToken).safeTransfer(_wallet, _amount);
      emit DistributeReward(_wallet, _amount);
    }
  }

  function _burnRewards(uint256 _burnAmount) internal {
    try IPEAS(rewardsToken).burn(_burnAmount) {} catch {
      IERC20(rewardsToken).safeTransfer(address(0xdead), _burnAmount);
    }
  }

  function _getYieldFees()
    internal
    view
    returns (uint256 _admin, uint256 _burn)
  {
    IProtocolFees _fees = PROTOCOL_FEE_ROUTER.protocolFees();
    if (address(_fees) != address(0)) {
      _admin = _fees.yieldAdmin();
      _burn = _fees.yieldBurn();
    }
  }

  function beginningOfMonth(uint256 _timestamp) public pure returns (uint256) {
    (, , uint256 _dayOfMonth) = BokkyPooBahsDateTimeLibrary.timestampToDate(
      _timestamp
    );
    return _timestamp - ((_dayOfMonth - 1) * 1 days) - (_timestamp % 1 days);
  }

  function claimReward(address _wallet) external override {
    _distributeReward(_wallet);
    emit ClaimReward(_wallet);
  }

  function getUnpaid(address _wallet) public view returns (uint256) {
    if (shares[_wallet] == 0) {
      return 0;
    }
    uint256 earnedRewards = _cumulativeRewards(shares[_wallet]);
    uint256 rewardsExcluded = rewards[_wallet].excluded;
    if (earnedRewards <= rewardsExcluded) {
      return 0;
    }
    return earnedRewards - rewardsExcluded;
  }

  function _cumulativeRewards(uint256 _share) internal view returns (uint256) {
    return (_share * _rewardsPerShare) / PRECISION;
  }
}
