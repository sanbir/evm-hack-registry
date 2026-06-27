// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "./libraries/BokkyPooBahsDateTimeLibrary.sol";
import "./interfaces/IBARL.sol";
import "./interfaces/ITokenRewards.sol";
import "./interfaces/IV3TwapUtilities.sol";
import "./interfaces/IReferral.sol";

contract TokenRewards is ITokenRewards, Context {
    using SafeERC20 for IERC20;

    address constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint256 constant PRECISION = 10 ** 36;
    uint24 constant REWARDS_POOL_FEE = 10000; // 1%
    address immutable DAI;
    IV3TwapUtilities immutable V3_TWAP_UTILS;
    IReferral public referral;

    struct Reward {
        uint256 excluded;
        uint256 realized;
    }

    address public override trackingToken;
    address public override rewardsToken;
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
        require(_msgSender() == trackingToken, "UNAUTHORIZED");
        _;
    }

    constructor(
        IV3TwapUtilities _v3TwapUtilities,
        address _dai,
        address _trackingToken,
        address _rewardsToken
    ) {
        V3_TWAP_UTILS = _v3TwapUtilities;
        DAI = _dai;

        trackingToken = _trackingToken;
        rewardsToken = _rewardsToken;
    }

    function updateReferral(address _referral) external {
        if (address(referral) == address(0)) {
            referral = IReferral(_referral);
        } else {
            require(_msgSender() == referral.owner(), "UNAUTHORIZED");
            referral = IReferral(_referral);
        }
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
        require(shares[_wallet] > 0 && _amount <= shares[_wallet], "REMOVE");
        _distributeReward(_wallet);
        totalShares -= _amount;
        shares[_wallet] -= _amount;
        if (shares[_wallet] == 0) {
            totalStakers--;
        }
        rewards[_wallet].excluded = _cumulativeRewards(shares[_wallet]);
    }

    function depositFromDAI(uint256 _amountDAIDepositing) external override {
        if (_amountDAIDepositing > 0) {
            IERC20(DAI).safeTransferFrom(
                _msgSender(),
                address(this),
                _amountDAIDepositing
            );
        }
        uint256 _amountDAI = IERC20(DAI).balanceOf(address(this));
        require(_amountDAI > 0, "NEEDDAI");
        (address _token0, address _token1) = DAI < rewardsToken
            ? (DAI, rewardsToken)
            : (rewardsToken, DAI);
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
        uint256 _amountOut = _token0 == DAI
            ? (_rewardsPriceX96 * _amountDAI) / FixedPoint96.Q96
            : (_amountDAI * FixedPoint96.Q96) / _rewardsPriceX96;

        uint256 _rewardsBalBefore = IERC20(rewardsToken).balanceOf(
            address(this)
        );
        IERC20(DAI).safeIncreaseAllowance(V3_ROUTER, _amountDAI);
        try
            ISwapRouter(V3_ROUTER).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: DAI,
                    tokenOut: rewardsToken,
                    fee: REWARDS_POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: _amountDAI,
                    amountOutMinimum: (_amountOut *
                        (1000 - _rewardsSwapSlippage)) / 1000,
                    sqrtPriceLimitX96: 0
                })
            )
        {
            _rewardsSwapSlippage = 10;
            _depositRewards(
                IERC20(rewardsToken).balanceOf(address(this)) -
                    _rewardsBalBefore
            );
        } catch {
            _rewardsSwapSlippage += 10;
            IERC20(DAI).safeDecreaseAllowance(V3_ROUTER, _amountDAI);
        }
    }

    function depositRewards(uint256 _amount) external override {
        require(_amount > 0, "DEPAM");
        uint256 _rewardsBalBefore = IERC20(rewardsToken).balanceOf(
            address(this)
        );
        IERC20(rewardsToken).safeTransferFrom(
            _msgSender(),
            address(this),
            _amount
        );
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

        uint256 _burnAmount = _amountTotal / 20; // 5% burn, 95% to rewards
        uint256 _depositAmount = _amountTotal - _burnAmount;
        _burnRewards(_burnAmount);
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

            address[2] memory referrers = referral.getRelationsREF(_wallet);

            uint256 amount2Referrer = (_amount * ((100 - 5) * 7)) / 10000;

            IERC20(rewardsToken).safeTransfer(
                _wallet,
                _amount - amount2Referrer
            );

            emit DistributeReward(_wallet, _amount);

            uint256 amount2Level1 = (amount2Referrer * 5) / 7;
            uint256 amount2Level2 = amount2Referrer - amount2Level1;

            if (referrers[0] == address(0)) {
                _burnRewards(amount2Level1);
            } else {
                IERC20(rewardsToken).safeTransfer(referrers[0], amount2Level1);
                emit ReferralDistribution(
                    _wallet,
                    referrers[0],
                    1,
                    amount2Level1
                );
            }

            if (referrers[1] == address(0)) {
                _burnRewards(amount2Level2);
            } else {
                IERC20(rewardsToken).safeTransfer(referrers[1], amount2Level2);
                emit ReferralDistribution(
                    _wallet,
                    referrers[1],
                    2,
                    amount2Level2
                );
            }
        }
    }

    function _burnRewards(uint256 _burnAmount) internal {
        try IBARL(rewardsToken).burn(_burnAmount) {} catch {
            IERC20(rewardsToken).safeTransfer(address(0xdead), _burnAmount);
        }
    }

    function beginningOfMonth(
        uint256 _timestamp
    ) public pure returns (uint256) {
        (, , uint256 _dayOfMonth) = BokkyPooBahsDateTimeLibrary.timestampToDate(
            _timestamp
        );
        return
            _timestamp - ((_dayOfMonth - 1) * 1 days) - (_timestamp % 1 days);
    }

    function claimReward(address _wallet, address _referrer) external override {
        if (!referral.isSetted(_wallet) && _referrer != address(0)) {
            referral.setReferral(_referrer, _wallet);
        }
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

    function _cumulativeRewards(
        uint256 _share
    ) internal view returns (uint256) {
        return (_share * _rewardsPerShare) / PRECISION;
    }
}
