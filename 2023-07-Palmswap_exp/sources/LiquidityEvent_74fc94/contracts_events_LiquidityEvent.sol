// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import {GovernableUpgradeable} from "../access/GovernableUpgradeable.sol";
import "../core/interfaces/IPlpManager.sol";
import "./interfaces/IVestPalm.sol";
import "./interfaces/ILiquidityEvent.sol";
import "../staking/interfaces/IRewardTracker.sol";

contract LiquidityEvent is
    ILiquidityEvent,
    GovernableUpgradeable,
    ReentrancyGuardUpgradeable
{
    struct Tier {
        uint256 tier; // 0 in Tier 1
        uint256 rewardPerToken; // 5 * 10^18 in Tier 1 (5 PALM per PLP)
        uint256 upper; // 500000 * 10^18 in Tier 1
        uint256 lower; // 0 in Tier 1
        uint256 allocatedPlp; // upper - lower
        uint256 filled; // Total filled PLP amount
    }

    struct UserInfo {
        uint256 purchased; // Total purchased PLP amount
        uint256 destroyed; // Total PLP amounts that is used for destroying the rewards
        // e.g If a user bought 1000 PLPs at tier 1 and 2000 PLPs at tier 3
        uint256[] tiers; // [0, 2]
        uint256[] amountsPerTier; // [1000, 2000]
    }

    bool public override eventEnded;
    bool public stopped;

    uint256 public totalAllocatedPlp;
    uint256 public totalPurchased;
    uint256 public currentTier;
    uint256 public maxTier;

    address public plp;
    IRewardTracker public stakedPlpTracker;
    IPlpManager public plpManager;
    IVestPalm public vester;

    mapping(uint256 => Tier) public tierInfo;
    mapping(address => UserInfo) public userInfo;
    mapping(address => bool) public isWhitelisted;

    uint256 public endWhitelistTime;

    event PurchasePlp(
        address user,
        uint256 currentTier,
        uint256 amountIn,
        uint256 plpOut
    );

    event PlpDestroy(address indexed account, uint256 amount);
    event StakePlp(
        address indexed account,
        uint256 amountIn,
        uint256 amountOut
    );
    event UnstakePlp(
        address indexed account,
        uint256 amountIn,
        uint256 amountOut
    );

    event LpeStop(bool);
    event EventEnd(bool);

    event TierSet(
        uint256 tier,
        uint256 rewardPerToken,
        uint256 lower,
        uint256 upper
    );

    event MaxTierSet(uint256);

    event WhitelistTimeSet(uint256);

    function initialize(
        address _stakedPlpTracker,
        address _plpManager,
        address _vester
    ) public initializer {
        __GovernableUpgradeable_init();
        __ReentrancyGuard_init();

        stakedPlpTracker = IRewardTracker(_stakedPlpTracker);
        plpManager = IPlpManager(_plpManager);
        plp = plpManager.plp();
        vester = IVestPalm(_vester);
    }

    function setStopped(bool _stopped) external onlyGov {
        stopped = _stopped;

        emit LpeStop(_stopped);
    }

    function setEventEnded(bool _ended) external onlyGov {
        eventEnded = _ended;
        emit EventEnd(_ended);
    }

    function setTier(
        uint256 _tier,
        uint256 _rewardPerToken,
        uint256 _lower,
        uint256 _upper
    ) external onlyGov {
        require(_tier <= maxTier, "LPE: >maxTier");

        uint256 _allocatedPlp = _upper - _lower;

        tierInfo[_tier].tier = _tier;
        tierInfo[_tier].rewardPerToken = _rewardPerToken;

        if (tierInfo[_tier].upper != 0)
            // if the tier is already set
            totalAllocatedPlp -= tierInfo[_tier].allocatedPlp;

        tierInfo[_tier].lower = _lower;
        tierInfo[_tier].upper = _upper;

        tierInfo[_tier].allocatedPlp = _allocatedPlp;
        totalAllocatedPlp += _allocatedPlp;

        emit TierSet(_tier, _rewardPerToken, _lower, _upper);
    }

    function setMaxTier(uint256 _max) external onlyGov {
        maxTier = _max;

        emit MaxTierSet(_max);
    }

    function balanceOf(address _account) external view returns (uint256) {
        return stakedPlpTracker.stakedAmounts(_account);
    }

    function getAmountsOut(
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        amountOut = plpManager.estimatePlpOut(_amountIn);
    }

    function getRewardsAmount(
        uint256 _tierId,
        uint256 _plpAmount
    ) public view returns (uint256) {
        return (tierInfo[_tierId].rewardPerToken * _plpAmount) / 1 ether;
    }

    function getUserInfo(
        address account
    ) public view returns (UserInfo memory) {
        return userInfo[account];
    }

    function getAmountsIn(
        uint256 _amountOut
    ) external view returns (uint256 amountIn) {
        amountIn = plpManager.estimateTokenIn(_amountOut);
    }

    function purchasePlp(
        uint256 _amountIn,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external override nonReentrant returns (uint256 amountOut) {
        require(!stopped, "LPE: stopped");
        require(!eventEnded, "LPE: event ended");
        require(_amountIn > 0, "LPE: invalid _amount");

        _checkEligible(msg.sender);

        address _account = msg.sender;
        amountOut = _mintAndStakePlp(_amountIn, _minUsdp, _minPlp);

        totalPurchased += amountOut;

        require(
            totalPurchased <= totalAllocatedPlp,
            "LPE: all tiers are filled"
        );

        PurchaseInfo[] memory pInfo = _updateStorageInfo(
            _account,
            _amountIn,
            amountOut
        );

        vester.deposit(_account, pInfo);

        emit PurchasePlp(_account, currentTier, _amountIn, amountOut);
    }

    function mintAndStakePlp(
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external override nonReentrant returns (uint256) {
        require(!stopped, "LPE: stopped");
        require(eventEnded, "LPE: event is ongoing");
        require(_amount > 0, "LPE: invalid _amount");

        return _mintAndStakePlp(_amount, _minUsdp, _minPlp);
    }

    function _mintAndStakePlp(
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) internal returns (uint256) {
        address _account = msg.sender;

        uint256 plpAmount = IPlpManager(plpManager).addLiquidityForAccount(
            _account,
            _account,
            _amount,
            _minUsdp,
            _minPlp
        );
        IRewardTracker(stakedPlpTracker).stakeForAccount(
            _account,
            _account,
            plp,
            plpAmount
        );

        emit StakePlp(_account, _amount, plpAmount);

        return plpAmount;
    }

    function unstakeAndRedeemPlp(
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        require(!stopped, "LPE: stopped");
        require(_plpAmount > 0, "LPE: invalid _plpAmount");

        address account = msg.sender;
        IRewardTracker(stakedPlpTracker).unstakeForAccount(
            account,
            plp,
            _plpAmount,
            account
        );
        uint256 amountOut = IPlpManager(plpManager).removeLiquidityForAccount(
            account,
            _plpAmount,
            _minOut,
            _receiver
        );

        emit UnstakePlp(account, _plpAmount, amountOut);

        _afterRedeemPlp(account);
        return amountOut;
    }

    function claimFee() external nonReentrant {
        address account = msg.sender;
        IRewardTracker(stakedPlpTracker).claimForAccount(account, account);
    }

    function _updateStorageInfo(
        address _account,
        uint256 _amountIn,
        uint256 _plpOut
    ) internal returns (PurchaseInfo[] memory pInfo) {
        uint256 _activeTier;
        uint256 _currentTier = currentTier;
        uint256 _length;
        uint256 i;
        uint256 _maxTier = maxTier;

        UserInfo storage _userInfo = userInfo[_account];
        _userInfo.purchased += _plpOut;

        for (i = _currentTier; i <= _maxTier; ++i) {
            if (tierInfo[i].upper > totalPurchased) {
                _activeTier = i;
                break;
            }
        }

        _length = tierInfo[_activeTier].lower == totalPurchased
            ? _activeTier - _currentTier
            : _activeTier - _currentTier + 1;

        pInfo = new PurchaseInfo[](_length);

        if (_activeTier > _currentTier) {
            uint256 _toFill;
            uint256 _fillAmount;
            uint256 _propAmountIn;
            uint256 _denominator = _plpOut;
            Tier storage _tierInfo;

            for (i = _currentTier; i <= _activeTier; ++i) {
                _tierInfo = tierInfo[i];

                _toFill = _tierInfo.allocatedPlp - _tierInfo.filled;
                _fillAmount = MathUpgradeable.min(_toFill, _plpOut);

                _tierInfo.filled += _fillAmount;
                _propAmountIn = (_amountIn * _fillAmount) / _denominator;

                pInfo[i - _currentTier] = PurchaseInfo({
                    tier: i,
                    amountIn: _propAmountIn,
                    amountOut: _fillAmount,
                    rewards: getRewardsAmount(i, _fillAmount)
                });

                _updateUserTierInfoArray(_userInfo, i, _fillAmount);

                if (_plpOut >= _toFill) _plpOut -= _toFill;
            }
            currentTier = _activeTier;
        } else {
            tierInfo[_currentTier].filled += _plpOut;

            pInfo[0] = PurchaseInfo({
                tier: _currentTier,
                amountIn: _amountIn,
                amountOut: _plpOut,
                rewards: getRewardsAmount(_currentTier, _plpOut)
            });

            _updateUserTierInfoArray(_userInfo, currentTier, _plpOut);
        }
    }

    function _updateUserTierInfoArray(
        UserInfo storage _userInfo,
        uint256 _tierId,
        uint256 _amount
    ) internal {
        if (_userInfo.tiers.length != 0) {
            uint256 _lastIndex = _userInfo.tiers.length - 1;
            uint256 _lastTier = _userInfo.tiers[_lastIndex];

            if (_tierId != _lastTier) {
                _userInfo.tiers.push(_tierId);
                _userInfo.amountsPerTier.push(_amount);
            } else {
                _userInfo.amountsPerTier[_lastIndex] += _amount;
            }
        } else {
            _userInfo.tiers.push(_tierId);
            _userInfo.amountsPerTier.push(_amount);
        }
    }

    function previewDestroyAmounts(
        address _account,
        uint256 _plpAmount
    )
        external
        view
        returns (
            uint256[] memory indexes,
            uint256[] memory allocatedRewards,
            uint256[] memory savedRewards,
            uint256[] memory destroyedRewards
        )
    {
        uint256 _balance = IERC20Upgradeable(plp).balanceOf(_account) +
            stakedPlpTracker.stakedAmounts(_account) -
            _plpAmount;
        UserInfo memory _userInfo = userInfo[_account];

        if ((_balance + _userInfo.destroyed) >= _userInfo.purchased)
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0)
            );

        uint256 _missingPlp = _userInfo.purchased -
            _userInfo.destroyed -
            _balance;

        uint256[] memory _tiers = new uint256[](_userInfo.tiers.length);
        uint256 _length;

        for (uint256 i = _tiers.length; i > 0; --i) {
            _tiers[_length] = _userInfo.tiers[i - 1];
            ++_length;

            uint256 _amountsPerTier = _userInfo.amountsPerTier[i - 1];

            if (_missingPlp <= _amountsPerTier) break;
            _missingPlp -= _amountsPerTier;
        }

        (VestingSchedule[] memory _schedules, uint256 _scheduleLength) = vester
            .previewRewardsDestroy(_account, _tiers, _length);

        indexes = new uint256[](_scheduleLength);
        savedRewards = new uint256[](_scheduleLength);
        allocatedRewards = new uint256[](_scheduleLength);
        destroyedRewards = new uint256[](_scheduleLength);

        for (uint256 i; i < _scheduleLength; ++i) {
            indexes[i] = _schedules[i].index;
            allocatedRewards[i] = _schedules[i].allocated;
            savedRewards[i] = _schedules[i].claimed + _schedules[i].notClaimed;
            destroyedRewards[i] =
                _schedules[i].allocated -
                _schedules[i].claimed -
                _schedules[i].notClaimed;
        }
    }

    function _afterRedeemPlp(address _account) internal {
        uint256 _balance = IERC20Upgradeable(plp).balanceOf(_account) +
            stakedPlpTracker.stakedAmounts(_account);
        UserInfo memory _userInfo = userInfo[_account];

        if ((_balance + _userInfo.destroyed) >= _userInfo.purchased) return;

        uint256 _missingPlp = _userInfo.purchased -
            _userInfo.destroyed -
            _balance;

        uint256[] memory _tiers = new uint256[](_userInfo.tiers.length);
        uint256 _length;

        for (uint256 i = _tiers.length; i > 0; --i) {
            _tiers[_length] = _userInfo.tiers[i - 1];
            ++_length;

            userInfo[_account].tiers.pop();
            userInfo[_account].amountsPerTier.pop();

            uint256 _amountsPerTier = _userInfo.amountsPerTier[i - 1];

            userInfo[_account].destroyed += _amountsPerTier;

            emit PlpDestroy(_account, _amountsPerTier);

            if (_missingPlp <= _amountsPerTier) break;
            _missingPlp -= _amountsPerTier;
        }

        if (_length != 0) vester.resetUserReward(_account, _tiers, _length);
    }

    function setWhitelistEndTime(uint256 _end) external onlyGov {
        require(_end != 0, "!endTime");
        require(_end > block.timestamp, "invalid end");

        endWhitelistTime = _end;

        emit WhitelistTimeSet(_end);
    }

    function setWhitelistAddresses(
        address[] calldata _accounts,
        bool _whitelist
    ) external onlyGov {
        for (uint256 i; i < _accounts.length; ++i) {
            isWhitelisted[_accounts[i]] = _whitelist;
        }
    }

    function _checkEligible(address account) internal view {
        if (endWhitelistTime == 0) return;
        else if (block.timestamp <= endWhitelistTime)
            require(isWhitelisted[account], "!whitelist");
    }
}
