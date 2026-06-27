// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import './interfaces/IStaking.sol';
import './interfaces/ISettings.sol';
import './interfaces/IEraManager.sol';
import './interfaces/IRewardsStaking.sol';
import './interfaces/ISQToken.sol';
import './interfaces/IDisputeManager.sol';
import './Constants.sol';
import './utils/MathUtil.sol';
import './utils/SQParameter.sol';

/**
 * @title Staking Contract
 * @notice ### Overview
 * The Staking contract hold and track all staked SQT Token and runner commission rate. The entries for the runners and delegators to
 * stake/unstake, delegate/undelegate to available runners and withdraw their SQT Token are organized in StakingManager contract though.
 *
 * In the contract, we may hold current and future value for staking amount and commission rate. We use a special struct
 * { era, valueAt, valueAfter } to indicate which value should be used for current era. We design this to separate user requesting a
 * staking change and the time the change actually become effective.
 *
 * Unbonding is also managed in this contract. There is a lock period for each unbonding request. We manage each request separately.
 * There is a unbonding request limit as specified in maxUnbondingRequest. Though we do allow more request coming through, when
 * it happens, the new request will be merged to the most recent request, and refresh its unlock date.
 * Unbonding requests have a source field, when user cancel a request, the token goes back to its original place. (add back to someone's stake)
 * if a commission unbonding is cancelled, it will be added to runner's stake.
 * there are some cases cancellation may fail, e.g when the original runner is unregistered.
 *
 * ## Terminology
 * stake -- Runners must stake SQT Token to themself and not less than the minimumStakingAmount we set in IndexerRegistry contract
 * delegate -- Delegators can delegate SQT Token to any runner to share Runner‘s Rewards.
 * total staked amount -- runner's stake amount + total delegate amount.
 * The Runner staked amount effects its max acceptable delegation amount.
 * The total staked amount of a Runner effects the maximum allocation it allocate to different deployments.
 *
 * ## Detail
 * The change of stake or delegate amount and commission rate affects the rewards distribution, when
 * users make these changes, we call onStakeChange()/onICRChnage() from rewardsStaking/rewardsPool contract to notify it to
 * apply these changes for future distribution.
 * In our design rewardsStaking contract apply the first stake change and commission rate change immediately when
 * a runner register. Later on all the stake change apply at next Era, commission rate apply at two Eras later.
 *
 * Runners need to stake SQT Token at registration and the staked amount effects its max acceptable delegation amount.
 * The implementation of stake() is different with delegate().
 * - stake() is for Runners to stake on themself. There has no stake amount limitation. First stake must be called from IndexerRegistry.
 * - delegate() is for delegators to delegate on an runner and need to consider the runner's delegation limitation.
 *
 * Also in this contarct we has two entries to set commission rate for runners.
 * setInitialCommissionRate() is called by IndexrRegister contract when runner register, this change need to take effect immediately.
 * setCommissionRate() is called by Runners to set their commission rate, and will be take effect after two Eras.
 *
 * Since Runner must keep the minimumStakingAmount, so the implementation of unstake() also different with undelegate().
 * - unstake() is for Runners to unstake their staking token. A runner can not unstake to below minimumStakingAmount unless
 * the runner unregister from the network.
 * - undelegate() is for delegator to undelegate from a Runner, it can be called by Delegators. it will take a locking period until the token
 * become available to withdraw.
 * Delegators can undelegate all their delegated tokens at one time.
 * Tokens will transfer to user's account after the lockPeriod when users apply withdraw.
 * Every widthdraw will cost a fix rate fees(unbondFeeRate), and these fees will be transferred to treasury.
 */
contract Staking is IStaking, Initializable, OwnableUpgradeable, SQParameter {
    using SafeERC20 for IERC20;
    using MathUtil for uint256;

    // -- Storage --

    ISettings public settings;

    /**
     * The ratio of total stake amount to runner self stake amount to limit the
     * total delegation amount. Initial value is set to 10, which means the total
     * stake amount cannot exceed 10 times the runner self stake amount.
     */
    uint256 public indexerLeverageLimit;

    // The rate of token burn when withdraw.
    uint256 public unbondFeeRate;

    // Lock period for withdraw, timestamp unit
    uint256 public lockPeriod;

    // Number of registered runners.
    uint256 public indexerLength;

    // Max limit of unbonding requests
    uint256 public maxUnbondingRequest;

    // Staking address by runner number.
    mapping(uint256 => address) public indexers;

    // Runner number by staking address.
    mapping(address => uint256) public indexerNo;

    // Staking amount per runner address.
    mapping(address => StakingAmount) public totalStakingAmount;

    // Delegator address -> unbond request index -> amount&startTime
    mapping(address => mapping(uint256 => UnbondAmount)) public unbondingAmount;

    // Delegator address -> length of unbond requests
    mapping(address => uint256) public unbondingLength;

    // Delegator address -> length of widthdrawn requests
    mapping(address => uint256) public withdrawnLength;

    // Active delegation from delegator to runner, delegator->runner->amount
    mapping(address => mapping(address => StakingAmount)) public delegation;

    // Each delegator total locked amount, delegator->amount
    // LockedAmount include stakedAmount + amount in locked period
    mapping(address => uint256) public lockedAmount;

    // Actively staking runners by delegator
    mapping(address => mapping(uint256 => address)) public stakingIndexers;

    // Delegating runner number by delegator and runner
    mapping(address => mapping(address => uint256)) public stakingIndexerNos;

    // Staking runner lengths
    mapping(address => uint256) public stakingIndexerLengths;

    // Instant delegation quota per era (per wallet)
    uint256 public instantDelegationQuota;

    // Era window percentage for instant delegation (in perMill, e.g., 700,000 = 70%)
    uint256 public instantEraWindowPercent;

    // Instant quota usage tracking

    // Track instant quota used per delegator: delegator => QuotaUsage
    mapping(address => InstantQuotaUsage) public instantQuotaUsed;

    // -- Events --

    /**
     * @dev Emitted when stake to an Runner.
     */
    event DelegationAdded(address indexed source, address indexed runner, uint256 amount);

    /**
     * @dev Emitted when stake to an Runner, with instant indicator.
     */
    event DelegationAdded2(
        address indexed source,
        address indexed runner,
        uint256 amount,
        bool instant
    );

    /**
     * @dev Emitted when unstake to an Runner.
     */
    event DelegationRemoved(address indexed source, address indexed runner, uint256 amount);

    /**
     * @dev Emitted when request unbond.
     */
    event UnbondRequested(
        address indexed source,
        address indexed runner,
        uint256 amount,
        uint256 index,
        UnbondType _type
    );

    /**
     * @dev Emitted when request withdraw.
     */
    event UnbondWithdrawn(address indexed source, uint256 amount, uint256 fee, uint256 index);

    /**
     * @dev Emitted when delegtor cancel unbond request.
     */
    event UnbondCancelled(
        address indexed source,
        address indexed runner,
        uint256 amount,
        uint256 index
    );

    modifier onlyStakingManager() {
        require(msg.sender == settings.getContractAddress(SQContracts.StakingManager), 'G007');
        _;
    }

    // -- Functions --

    /**
     * @dev Initialize this contract.
     */
    function initialize(
        ISettings _settings,
        uint256 _lockPeriod,
        uint256 _unbondFeeRate
    ) external initializer {
        __Ownable_init();

        indexerLeverageLimit = 10;
        maxUnbondingRequest = 20;

        unbondFeeRate = _unbondFeeRate;
        lockPeriod = _lockPeriod;
        settings = _settings;

        emit Parameter('indexerLeverageLimit', abi.encodePacked(indexerLeverageLimit));
        emit Parameter('maxUnbondingRequest', abi.encodePacked(maxUnbondingRequest));
        emit Parameter('unbondFeeRate', abi.encodePacked(unbondFeeRate));
        emit Parameter('lockPeriod', abi.encodePacked(lockPeriod));
    }

    function setSettings(ISettings _settings) external onlyOwner {
        settings = _settings;
    }

    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
        emit Parameter('lockPeriod', abi.encodePacked(lockPeriod));
    }

    function setIndexerLeverageLimit(uint256 _runnerLeverageLimit) external onlyOwner {
        indexerLeverageLimit = _runnerLeverageLimit;
        emit Parameter('indexerLeverageLimit', abi.encodePacked(indexerLeverageLimit));
    }

    function setUnbondFeeRateBP(uint256 _unbondFeeRate) external onlyOwner {
        require(_unbondFeeRate < PER_MILL, 'S001');
        unbondFeeRate = _unbondFeeRate;
        emit Parameter('unbondFeeRate', abi.encodePacked(unbondFeeRate));
    }

    function setMaxUnbondingRequest(uint256 maxNum) external onlyOwner {
        maxUnbondingRequest = maxNum;
        emit Parameter('maxUnbondingRequest', abi.encodePacked(maxUnbondingRequest));
    }

    /**
     * @dev when Era update if valueAfter is the effective value, swap it to valueAt,
     * so later on we can update valueAfter without change current value
     * require it idempotent.
     */
    function reflectEraUpdate(address _source, address _runner) public {
        uint256 eraNumber = IEraManager(settings.getContractAddress(SQContracts.EraManager))
            .safeUpdateAndGetEra();
        _reflectStakingAmount(eraNumber, delegation[_source][_runner]);
        _reflectStakingAmount(eraNumber, totalStakingAmount[_runner]);
    }

    function _reflectStakingAmount(uint256 eraNumber, StakingAmount storage stakeAmount) private {
        if (stakeAmount.era < eraNumber) {
            stakeAmount.era = eraNumber;
            stakeAmount.valueAt = stakeAmount.valueAfter;
        }
    }

    function checkDelegateLimitation(
        address _runner,
        uint256 _amount
    ) external view onlyStakingManager {
        require(
            delegation[_runner][_runner].valueAfter * indexerLeverageLimit >=
                totalStakingAmount[_runner].valueAfter + _amount,
            'S002'
        );
    }

    function addRunner(address _runner) external onlyStakingManager {
        _requireNotBlacklisted(settings, _runner);

        indexers[indexerLength] = _runner;
        indexerNo[_runner] = indexerLength;
        indexerLength++;
    }

    function removeRunner(address _runner) external onlyStakingManager {
        uint256 indexerIndex = indexerNo[_runner];
        indexers[indexerIndex] = indexers[indexerLength - 1];
        indexerNo[indexers[indexerLength - 1]] = indexerIndex;
        indexerLength--;
        delete indexerNo[_runner];
        delete indexers[indexerLength];
    }

    function removeUnbondingAmount(
        address _source,
        uint256 _unbondReqId
    ) external onlyStakingManager {
        UnbondAmount memory ua = unbondingAmount[_source][_unbondReqId];
        delete unbondingAmount[_source][_unbondReqId];

        uint256 firstIndex = withdrawnLength[_source];
        uint256 lastIndex = unbondingLength[_source] - 1;
        if (_unbondReqId == firstIndex) {
            for (uint256 i = firstIndex; i <= lastIndex; i++) {
                if (unbondingAmount[_source][i].amount == 0) {
                    withdrawnLength[_source]++;
                } else {
                    break;
                }
            }
        } else if (_unbondReqId == lastIndex) {
            for (uint256 i = lastIndex; i >= firstIndex; i--) {
                if (unbondingAmount[_source][i].amount == 0) {
                    unbondingLength[_source]--;
                } else {
                    break;
                }
            }
        }

        emit UnbondCancelled(_source, ua.indexer, ua.amount, _unbondReqId);
    }

    function addDelegation(
        address _source,
        address _runner,
        uint256 _amount,
        bool instant
    ) external {
        _requireNotBlacklisted(settings, _source);
        _requireNotBlacklisted(settings, _runner);

        require(
            msg.sender == settings.getContractAddress(SQContracts.StakingManager) ||
                msg.sender == address(this),
            'G008'
        );
        require(_amount > 0, 'S003');

        reflectEraUpdate(_source, _runner);

        if (this.isEmptyDelegation(_source, _runner)) {
            stakingIndexerNos[_source][_runner] = stakingIndexerLengths[_source];
            stakingIndexers[_source][stakingIndexerLengths[_source]] = _runner;
            stakingIndexerLengths[_source]++;
        }
        // first stake from runner
        bool firstStake = this.isEmptyDelegation(_runner, _runner) &&
            totalStakingAmount[_runner].valueAt == 0 &&
            totalStakingAmount[_runner].valueAfter == 0;
        if (firstStake) {
            require(_source == _runner, 'S004');
            delegation[_source][_runner].valueAt = _amount;
            totalStakingAmount[_runner].valueAt = _amount;
            delegation[_source][_runner].valueAfter = _amount;
            totalStakingAmount[_runner].valueAfter = _amount;
        } else {
            if (instant) {
                delegation[_source][_runner].valueAt += _amount;
                totalStakingAmount[_runner].valueAt += _amount;
            }
            delegation[_source][_runner].valueAfter += _amount;
            totalStakingAmount[_runner].valueAfter += _amount;
        }
        lockedAmount[_source] += _amount;
        _onDelegationChange(_source, _runner);

        emit DelegationAdded2(_source, _runner, _amount, instant);
    }

    /**
     * @dev Transfer tokens from source to this contract (for instant delegation)
     * @param _source The source address
     * @param _amount The amount to transfer
     */
    function transferDelegationTokens(
        address _source,
        uint256 _amount
    ) external onlyStakingManager {
        _requireNotBlacklisted(settings, _source);

        IERC20(settings.getContractAddress(SQContracts.SQToken)).safeTransferFrom(
            _source,
            address(this),
            _amount
        );
    }

    function removeDelegation(address _source, address _runner, uint256 _amount) external {
        _requireNotBlacklisted(settings, _source);

        require(
            msg.sender == settings.getContractAddress(SQContracts.StakingManager) ||
                msg.sender == address(this),
            'G008'
        );

        reflectEraUpdate(_source, _runner);

        require(delegation[_source][_runner].valueAfter >= _amount && _amount > 0, 'S005');

        delegation[_source][_runner].valueAfter -= _amount;
        totalStakingAmount[_runner].valueAfter -= _amount;

        _onDelegationChange(_source, _runner);

        emit DelegationRemoved(_source, _runner, _amount);
    }

    /**
     * @dev When the delegation change nodify rewardsStaking to deal with the change.
     */
    function _onDelegationChange(address _source, address _runner) internal {
        IRewardsStaking rewardsStaking = IRewardsStaking(
            settings.getContractAddress(SQContracts.RewardsStaking)
        );
        rewardsStaking.onStakeChange(_runner, _source);
    }

    function startUnbond(
        address _source,
        address _runner,
        uint256 _amount,
        UnbondType _type
    ) external {
        _requireNotBlacklisted(settings, _source);

        require(
            msg.sender == settings.getContractAddress(SQContracts.StakingManager) ||
                msg.sender == address(this),
            'G008'
        );
        uint256 nextIndex = unbondingLength[_source];
        if (_type == UnbondType.Undelegation) {
            require(nextIndex - withdrawnLength[_source] < maxUnbondingRequest - 1, 'S006');
        }

        if (_type != UnbondType.Commission) {
            this.removeDelegation(_source, _runner, _amount);
        }

        if (nextIndex - withdrawnLength[_source] == maxUnbondingRequest) {
            _type = UnbondType.Merge;
            nextIndex--;
        } else {
            unbondingLength[_source]++;
        }

        UnbondAmount storage uamount = unbondingAmount[_source][nextIndex];
        uamount.amount += _amount;
        uamount.startTime = block.timestamp;
        uamount.indexer = _runner;

        emit UnbondRequested(_source, _runner, _amount, nextIndex, _type);
    }

    /**
     * @dev Withdraw a single request.
     * burn the withdrawn fees and transfer the rest to delegator.
     */
    function withdrawARequest(address _source, uint256 _index) external onlyStakingManager {
        _requireNotBlacklisted(settings, _source);

        require(_index == withdrawnLength[_source], 'S009');
        require(block.timestamp >= unbondingAmount[_source][_index].startTime + lockPeriod, 'S016');
        withdrawnLength[_source]++;

        uint256 amount = unbondingAmount[_source][_index].amount;
        if (amount > 0) {
            // take specific percentage for fee
            uint256 feeAmount = MathUtil.mulDiv(unbondFeeRate, amount, PER_MILL);
            uint256 availableAmount = amount - feeAmount;

            address SQToken = settings.getContractAddress(SQContracts.SQToken);
            address treasury = settings.getContractAddress(SQContracts.Treasury);
            IERC20(SQToken).safeTransfer(treasury, feeAmount);
            IERC20(SQToken).safeTransfer(_source, availableAmount);

            lockedAmount[_source] -= amount;

            emit UnbondWithdrawn(_source, availableAmount, feeAmount, _index);
        }
    }

    function slashRunner(address _runner, uint256 _amount) external onlyStakingManager {
        uint256 amount = _amount;

        for (uint256 i = withdrawnLength[_runner]; i < unbondingLength[_runner]; i++) {
            if (amount > unbondingAmount[_runner][i].amount) {
                amount -= unbondingAmount[_runner][i].amount;
                delete unbondingAmount[_runner][i];
                withdrawnLength[_runner]++;
            } else if (amount == unbondingAmount[_runner][i].amount) {
                delete unbondingAmount[_runner][i];
                withdrawnLength[_runner]++;
                amount = 0;
                break;
            } else {
                unbondingAmount[_runner][i].amount -= amount;
                amount = 0;
                break;
            }
        }

        if (amount > 0) {
            delegation[_runner][_runner].valueAt -= amount;
            totalStakingAmount[_runner].valueAt -= amount;
            delegation[_runner][_runner].valueAfter -= amount;
            totalStakingAmount[_runner].valueAfter -= amount;
        }

        lockedAmount[_runner] -= _amount;

        IERC20(settings.getContractAddress(SQContracts.SQToken)).safeTransfer(
            settings.getContractAddress(SQContracts.DisputeManager),
            _amount
        );
    }

    function unbondCommission(address _runner, uint256 _amount) external {
        require(msg.sender == settings.getContractAddress(SQContracts.RewardsDistributor), 'G003');
        _requireNotBlacklisted(settings, _runner);

        lockedAmount[_runner] += _amount;
        this.startUnbond(_runner, _runner, _amount, UnbondType.Commission);
    }

    /**
     * @notice Update instant quota used for a delegator in a specific era
     * @param delegator The delegator address
     * @param era The era number
     * @param amount The amount to add to used quota
     */
    function updateInstantQuotaUsed(
        address delegator,
        uint256 era,
        uint256 amount
    ) external onlyStakingManager {
        InstantQuotaUsage storage usage = instantQuotaUsed[delegator];

        // If era changed, reset the quota usage
        if (usage.era != era) {
            usage.era = era;
            usage.amount = amount;
        } else {
            // Same era, accumulate
            usage.amount += amount;
        }
    }

    /**
     * @notice Set instant delegation parameters
     * @param _perEraQuota The quota per era per wallet
     * @param _windowPercent The era window percentage (in perMill)
     */
    function setInstantDelegationParams(
        uint256 _perEraQuota,
        uint256 _windowPercent
    ) external onlyOwner {
        require(_windowPercent <= PER_MILL, 'S015');
        instantDelegationQuota = _perEraQuota;
        instantEraWindowPercent = _windowPercent;

        emit Parameter('instantDelegationQuota', abi.encode(_perEraQuota));
        emit Parameter('instantEraWindowPercent', abi.encode(_windowPercent));
    }

    // -- Views --

    function isEmptyDelegation(address _source, address _runner) external view returns (bool) {
        return
            delegation[_source][_runner].valueAt == 0 &&
            delegation[_source][_runner].valueAfter == 0;
    }

    /**
     * @notice Get remaining instant quota for a delegator in a specific era
     * @param delegator The delegator address
     * @param era The era number
     * @return The remaining quota amount
     */
    function getInstantQuotaRemaining(
        address delegator,
        uint256 era
    ) external view returns (uint256) {
        InstantQuotaUsage memory usage = instantQuotaUsed[delegator];

        // If different era or not yet used, full quota available
        if (usage.era != era) {
            return instantDelegationQuota;
        }

        // Same era, return remaining
        return instantDelegationQuota > usage.amount ? instantDelegationQuota - usage.amount : 0;
    }
}
