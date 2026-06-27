// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITokenStake.sol";
import "./ITokenStakeSetting.sol";
import "../token_stake_apy/ITokenStakeApy.sol";
import "../market/IMarketplace.sol";
import "../oracle/Oracle.sol";
import "../stake/IStaking.sol";
import "../ranking/IRanking.sol";

contract TokenStake is ITokenStake, ITokenStakeSetting, Ownable, ERC721Holder {
    uint16 public maxFloor = 8;
    uint256 private unlocked = 1;
    uint256 public timeOpenStaking = 1689786000;
    uint256 public tokenDecimal = 1000000000000000000;
    uint256 public rankCommissionDuration = 62208000; // 24 month
    uint256 public poolDurationHasLimit = 12; // 12 month

    address public novaxToken;
    address public tokenStakeApy;
    address public marketplaceContract;
    address public rankingContract;

    mapping(address => address) public oracleContracts;

    // mapping to store amount staked to get reward
    mapping(uint16 => uint256) public amountConditions;

    // mapping to store commission percent when ref claim staking token
    mapping(uint16 => uint256) public commissionPercents;

    mapping(uint256 => uint256) public directCommissionPercents; // Ex: 500 = 5%

    uint256 public stakeTokenPoolLength = 6;
    uint256 public stakeIndex = 0;

    mapping(uint256 => StakeTokenPools) private stakeTokenPools;
    mapping(uint256 => StakedToken) private stakedToken;
    mapping(address => mapping(uint256 => uint256)) private totalUserStakedPoolToken;
    mapping(address => mapping(uint256 => uint256)) private totalUserStakedPoolUsd;

    mapping(address => uint256) private directCommission;
    mapping(address => uint256) private refClaimed;

    mapping(uint256 => uint256) public canNotWithdraw; // Stake id -> is Can not withdraw

    constructor(address _novaxToken, address _tokenStakeApy, address _marketplaceContract, address _oracleContract) {
        novaxToken = _novaxToken;
        tokenStakeApy = _tokenStakeApy;
        marketplaceContract = _marketplaceContract;
        oracleContracts[_novaxToken] = _oracleContract;
        initStakePool();
        initCommissionConditionUsd();
        initCommissionPercents();
        initDirectCommissionPercents();
    }

    modifier isTimeForStaking() {
        require(block.timestamp >= timeOpenStaking, "TS:T");
        _;
    }

    modifier lock() {
        require(unlocked == 1, "TS:L");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function initStakePool() internal {
        stakeTokenPools[0].poolId = 0;
        stakeTokenPools[0].maxStakePerWallet = 0;
        stakeTokenPools[0].duration = 0;
        stakeTokenPools[0].isPayProfit = false;
        stakeTokenPools[0].stakeToken = novaxToken;
        stakeTokenPools[0].earnToken = novaxToken;

        stakeTokenPools[1].poolId = 1;
        stakeTokenPools[1].maxStakePerWallet = 1000000000000000000000;
        stakeTokenPools[1].duration = 1;
        stakeTokenPools[1].isPayProfit = true;
        stakeTokenPools[1].stakeToken = novaxToken;
        stakeTokenPools[1].earnToken = novaxToken;

        stakeTokenPools[2].poolId = 2;
        stakeTokenPools[2].maxStakePerWallet = 3000000000000000000000;
        stakeTokenPools[2].duration = 3;
        stakeTokenPools[2].isPayProfit = true;
        stakeTokenPools[2].stakeToken = novaxToken;
        stakeTokenPools[2].earnToken = novaxToken;

        stakeTokenPools[3].poolId = 3;
        stakeTokenPools[3].maxStakePerWallet = 0;
        stakeTokenPools[3].duration = 6;
        stakeTokenPools[3].isPayProfit = true;
        stakeTokenPools[3].stakeToken = novaxToken;
        stakeTokenPools[3].earnToken = novaxToken;

        stakeTokenPools[4].poolId = 4;
        stakeTokenPools[4].maxStakePerWallet = 0;
        stakeTokenPools[4].duration = 12;
        stakeTokenPools[4].isPayProfit = true;
        stakeTokenPools[4].stakeToken = novaxToken;
        stakeTokenPools[4].earnToken = novaxToken;

        stakeTokenPools[5].poolId = 5;
        stakeTokenPools[5].maxStakePerWallet = 0;
        stakeTokenPools[5].duration = 24;
        stakeTokenPools[5].isPayProfit = true;
        stakeTokenPools[5].stakeToken = novaxToken;
        stakeTokenPools[5].earnToken = novaxToken;
    }

    function initCommissionConditionUsd() internal {
        amountConditions[0] = 0;
        amountConditions[1] = 500;
        amountConditions[2] = 1000;
        amountConditions[3] = 1500;
        amountConditions[4] = 2000;
        amountConditions[5] = 3000;
        amountConditions[6] = 4000;
        amountConditions[7] = 5000;
    }

    function initCommissionPercents() internal {
        commissionPercents[0] = 1500;
        commissionPercents[1] = 1000;
        commissionPercents[2] = 800;
        commissionPercents[3] = 500;
        commissionPercents[4] = 400;
        commissionPercents[5] = 300;
        commissionPercents[6] = 300;
        commissionPercents[7] = 200;
    }

    function initDirectCommissionPercents() internal {
        directCommissionPercents[4] = 600;
        directCommissionPercents[5] = 600;
    }

    function getTotalUserStakedToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserStakedUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getTotalUserStakedAvailableToken(address _user) public view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserStakedAvailableUsd(address _user) public view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getTotalUserClaimedToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueClaimed;
            }
        }
        return value;
    }

    function getTotalUserClaimedUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueClaimedUsd;
            }
        }
        return value;
    }

    function getTotalUserWithdrawToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserWithdrawUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getUserStakedPoolToken(address _user, uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getUserStakedPoolUsd(address _user, uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getPoolTotalStakeToken(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getPoolTotalStakeUsd(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getPoolTotalClaimToken(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId) {
                value += item.totalValueClaimed;
            }
        }
        return value;
    }

    function getPoolTotalClaimUsd(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId) {
                value += item.totalValueClaimedUsd;
            }
        }
        return value;
    }

    function getCommissionPercent(uint16 _level) public view override returns (uint256) {
        return commissionPercents[_level];
    }

    function getDirectCommission(address _user) external view override returns (uint256) {
        return directCommission[_user];
    }

    function getCommissionCondition(uint16 _level) external view override returns (uint256) {
        return amountConditions[_level];
    }

    function totalStakedToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueStake;
        }

        return total;
    }

    function totalStakedUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueStakeUsd;
        }

        return total;
    }

    function totalWithdrawToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            if (stakeItem.isWithdraw) {
                total += stakeItem.totalValueStake;
            }
        }

        return total;
    }

    function totalWithdrawUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            if (stakeItem.isWithdraw) {
                total += stakeItem.totalValueStakeUsd;
            }
        }

        return total;
    }

    function totalClaimedToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueClaimed;
        }

        return total;
    }

    function totalClaimedUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueClaimedUsd;
        }

        return total;
    }

    function getTeamStakingValue(address _wallet) external view override returns (uint256) {
        return getChildrenStakingValueInUsd(_wallet, 1, maxFloor);
    }

    function getChildrenStakingValueInUsd(address _wallet, uint256 _deep, uint256 _maxDeep) internal view returns (uint256) {
        if (_deep > _maxDeep) {
            return 0;
        }

        uint256 nftValue = 0;
        address[] memory childrenUser = IMarketplace(marketplaceContract).getF1ListForAccount(_wallet);

        if (childrenUser.length <= 0) {
            return 0;
        }

        for (uint256 i = 0; i < childrenUser.length; i++) {
            address f1 = childrenUser[i];
            nftValue += getTotalUserStakedAvailableToken(f1);
            nftValue += getChildrenStakingValueInUsd(f1, _deep + 1, _maxDeep);
        }

        return nftValue;
    }

    function getStakeTokenPool(uint256 _poolId) external view override returns (StakeTokenPools memory) {
        StakeTokenPools memory _stakeTokenPool = stakeTokenPools[_poolId];

        return _stakeTokenPool;
    }

    function getStakedToken(uint256 _stakeId) public view override returns (StakedToken memory) {
        return stakedToken[_stakeId];
    }

    function stake(uint256 _poolId, uint256 _stakeValue) external override lock {
        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        require(IERC20(stakeToken).balanceOf(msg.sender) >= _stakeValue, "TS:E");
        require(IERC20(stakeToken).allowance(msg.sender, address(this)) >= _stakeValue, "TS:A");
        require(IERC20(stakeToken).transferFrom(msg.sender, address(this), _stakeValue), "TS:T");

        uint256 totalUserStakePool = totalUserStakedPoolToken[msg.sender][_poolId] + _stakeValue;
        require(stakeTokenPools[_poolId].maxStakePerWallet == 0 || stakeTokenPools[_poolId].maxStakePerWallet >= totalUserStakePool, "TS:U");

        // insert data staking
        stakeIndex = stakeIndex + 1;
        uint256 stakeValueUsd = tokenToUsd(stakeToken, _stakeValue);

        // if pool duration = 0 => no limit for stake time, can claim every time
        uint256 unlockTimeEstimate = stakeTokenPools[_poolId].duration == 0 ? 0 : (block.timestamp + (2592000 * stakeTokenPools[_poolId].duration));
        stakedToken[stakeIndex].stakeId = stakeIndex;
        stakedToken[stakeIndex].userAddress = msg.sender;
        stakedToken[stakeIndex].poolId = _poolId;
        stakedToken[stakeIndex].startTime = block.timestamp;
        stakedToken[stakeIndex].lastClaimTime = block.timestamp;
        stakedToken[stakeIndex].unlockTime = unlockTimeEstimate;
        stakedToken[stakeIndex].totalValueStake = _stakeValue;
        stakedToken[stakeIndex].totalValueStakeUsd = stakeValueUsd;
        stakedToken[stakeIndex].isWithdraw = false;

        // update fixed data
        totalUserStakedPoolToken[msg.sender][_poolId] += _stakeValue;
        totalUserStakedPoolUsd[msg.sender][_poolId] += stakeValueUsd;

        payDirectCommission(msg.sender, _poolId, _stakeValue);
        if (stakeTokenPools[_poolId].duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, stakeValueUsd, true);
        }
        emit Staked(stakeIndex, _poolId, msg.sender, _stakeValue, block.timestamp, unlockTimeEstimate);
    }

    function claimAll(uint256[] memory _stakeIds) external override lock {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            claimInternal(_stakeIds[i]);
        }
    }

    function claimPool(uint256[] memory _stakeIds) external override lock {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            claimInternal(_stakeIds[i]);
        }
    }

    function claim(uint256 _stakeId) external override lock {
        claimInternal(_stakeId);
    }

    function tokenToUsd(address token, uint256 _tokenAmount) public view returns (uint256) {
        address oracleContract = oracleContracts[token];
        return (1000000 * _tokenAmount) / IOracle(oracleContract).convertUsdBalanceDecimalToTokenDecimal(1000000);
    }

    function usdToToken(address token, uint256 _usdAmount) public view returns (uint256) {
        address oracleContract = oracleContracts[token];
        return IOracle(oracleContract).convertUsdBalanceDecimalToTokenDecimal(_usdAmount);
    }

    function payDirectCommission(address _user, uint256 _poolId, uint256 _tokenAmount) internal {
        uint256 _directCommissionPercent = directCommissionPercents[_poolId];
        if (_directCommissionPercent == 0) {
            return;
        }

        address ref = IMarketplace(marketplaceContract).getReferralAccountForAccountExternal(_user);
        address systemWallet = IMarketplace(marketplaceContract).systemWallet();
        if (ref == address(0) || ref == systemWallet) {
            return;
        }

        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        uint256 commissionTokenAmount = (_tokenAmount * _directCommissionPercent) / 10000;
        uint256 commissionUsdAmount = tokenToUsd(stakeToken, commissionTokenAmount);
        commissionUsdAmount = IMarketplace(marketplaceContract).getCommissionCanEarn(ref, commissionUsdAmount);
        if (commissionUsdAmount == 0) {
            return;
        }

        commissionTokenAmount = usdToToken(stakeToken, commissionUsdAmount);
        require(IERC20(stakeToken).balanceOf(address(this)) >= commissionTokenAmount, "TS:E");
        require(IERC20(stakeToken).transfer(ref, commissionTokenAmount), "TS:U");
        directCommission[ref] += commissionUsdAmount;
        IMarketplace(marketplaceContract).updateTotalEarnAndCommission(ref, commissionUsdAmount);
    }

    function claimInternal(uint256 _stakeId) internal {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        require(_stakedUserToken.userAddress == msg.sender, "TS:O");
        uint256 totalUsdClaimDecimal = calculateUsdEarnedStake(_stakeId);
        if (totalUsdClaimDecimal == 0) {
            return;
        }

        address earnToken = stakeTokenPools[_stakedUserToken.poolId].earnToken;
        uint256 totalUsdClaimDecimalCanEarn = IMarketplace(marketplaceContract).getCommissionCanEarn(msg.sender, totalUsdClaimDecimal);
        require(totalUsdClaimDecimal == totalUsdClaimDecimalCanEarn, "TS:CE");
        uint256 totalTokenClaimDecimal = usdToToken(earnToken, totalUsdClaimDecimal);

        require(IERC20(earnToken).balanceOf(address(this)) >= totalTokenClaimDecimal, "TS:E");
        require(IERC20(earnToken).transfer(msg.sender, totalTokenClaimDecimal), "TS:U");
        IMarketplace(marketplaceContract).updateTotalEarnAndCommission(msg.sender, totalUsdClaimDecimal);

        // pay commission multi levels
        if (stakeTokenPools[_stakedUserToken.poolId].isPayProfit) {
            payCommissionMultiLevels(msg.sender, totalTokenClaimDecimal, earnToken);
        }

        stakedToken[_stakeId].totalValueClaimed += totalTokenClaimDecimal;
        stakedToken[_stakeId].totalValueClaimedUsd += totalUsdClaimDecimal;
        stakedToken[_stakeId].lastClaimTime = block.timestamp;

        if (stakeTokenPools[_stakedUserToken.poolId].duration >= 12 && (block.timestamp <= (rankCommissionDuration + _stakedUserToken.startTime))) {
            IRanking(rankingContract).payRankingCommission(msg.sender, totalUsdClaimDecimal);
        }

        emit Claimed(_stakeId, msg.sender, totalTokenClaimDecimal);
    }

    function payCommissionMultiLevels(address _user, uint256 _totalAmountStakeTokenWithDecimal, address earnToken) internal {
        address _marketplaceContract = marketplaceContract;
        address currentRef = IMarketplace(_marketplaceContract).getReferralAccountForAccountExternal(_user);
        address systemWallet = IMarketplace(_marketplaceContract).systemWallet();
        uint16 index = 0;
        uint16 _maxFloor = maxFloor;

        while (currentRef != address(0) && currentRef != systemWallet && index < _maxFloor) {
            bool canReward = possibleForCommission(currentRef, index);
            if (canReward) {
                // Transfer commission in token amount
                uint256 commissionTokenAmount = (_totalAmountStakeTokenWithDecimal * commissionPercents[index]) / 10000;
                uint256 commissionUsdAmount = tokenToUsd(earnToken, commissionTokenAmount);
                commissionUsdAmount = IMarketplace(_marketplaceContract).getCommissionCanEarn(currentRef, commissionUsdAmount);
                if (commissionUsdAmount > 0) {
                    commissionTokenAmount = usdToToken(earnToken, commissionUsdAmount);
                    require(commissionTokenAmount > 0, "TS:IC");
                    require(IERC20(earnToken).balanceOf(address(this)) >= commissionTokenAmount, "TS:E");
                    require(IERC20(earnToken).transfer(currentRef, commissionTokenAmount), "ST:U");
                    refClaimed[currentRef] = refClaimed[currentRef] + commissionTokenAmount;
                    IMarketplace(_marketplaceContract).updateCommissionStakeValueData(currentRef, commissionUsdAmount);
                }
            }
            currentRef = IMarketplace(_marketplaceContract).getReferralAccountForAccountExternal(currentRef);
            index++;
        }
    }

    function possibleForCommission(address _staker, uint16 _level) public view returns (bool) {
        uint256 saleValue = IMarketplace(marketplaceContract).getSaleValue(_staker);
        saleValue = saleValue / tokenDecimal;
        uint256 conditionAmount = amountConditions[_level];
        if (saleValue >= conditionAmount) {
            return true;
        }

        return false;
    }

    function calculateUsdEarnedStake(uint256 _stakeId) public view override returns (uint256) {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        if (_stakedUserToken.isWithdraw) {
            return 0;
        }
        uint256 totalTokenClaimDecimal = 0;
        uint256 index = ITokenStakeApy(tokenStakeApy).getMaxIndex(_stakedUserToken.poolId);
        uint256 apy = 0;
        for (uint256 i = 0; i < index; i++) {
            uint256 startTime = ITokenStakeApy(tokenStakeApy).getStartTime(_stakedUserToken.poolId)[i];
            uint256 endTime = ITokenStakeApy(tokenStakeApy).getEndTime(_stakedUserToken.poolId)[i];
            apy = ITokenStakeApy(tokenStakeApy).getPoolApy(_stakedUserToken.poolId)[i];
            // calculate token claim for each stake pool
            startTime = startTime >= _stakedUserToken.startTime ? startTime : _stakedUserToken.startTime;
            // _stakedUserToken.unlockTime == 0 mean no limit for this pool
            uint256 timeDuration = _stakedUserToken.unlockTime == 0 ? block.timestamp : (_stakedUserToken.unlockTime < block.timestamp ? _stakedUserToken.unlockTime : block.timestamp);
            endTime = endTime == 0 ? timeDuration : (endTime <= timeDuration ? endTime : timeDuration);

            if (startTime <= endTime) {
                totalTokenClaimDecimal += ((endTime - startTime) * apy * _stakedUserToken.totalValueStakeUsd) / 31104000 / 100000;
            }
        }

        if (totalTokenClaimDecimal > _stakedUserToken.totalValueClaimedUsd) {
            return totalTokenClaimDecimal - _stakedUserToken.totalValueClaimedUsd;
        }

        return 0;
    }

    function calculateTokenEarnedStake(uint256 _stakeId) public view override returns (uint256) {
        uint256 earnUsd = calculateUsdEarnedStake(_stakeId);
        if (earnUsd == 0) {
            return 0;
        }
        address earnToken = stakeTokenPools[stakedToken[_stakeId].poolId].earnToken;
        return usdToToken(earnToken, earnUsd);
    }

    function calculateTokenEarnedMulti(uint256[] memory _stakeIds) public view override returns (uint256) {
        uint256 _totalTokenClaimDecimal = 0;
        for (uint i = 0; i < _stakeIds.length; i++) {
            _totalTokenClaimDecimal += calculateTokenEarnedStake(_stakeIds[i]);
        }

        return _totalTokenClaimDecimal;
    }

    function withdraw(uint256 _stakeId) public override lock {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        require(_stakedUserToken.userAddress == msg.sender, "TS:O");
        require(!_stakedUserToken.isWithdraw, "TS:W");
        require(canNotWithdraw[_stakeId] == 0, "TS:C");
        require(_stakedUserToken.unlockTime <= block.timestamp, "TS:T");

        claimInternal(_stakeId);

        StakeTokenPools memory stakeTokenPool = stakeTokenPools[_stakedUserToken.poolId];
        address stakeToken = stakeTokenPool.stakeToken;
        uint256 withdrawTokenValue = usdToToken(stakeToken, _stakedUserToken.totalValueStakeUsd);
        require(IERC20(stakeToken).balanceOf(address(this)) >= withdrawTokenValue, "TS:E");
        require(IERC20(stakeToken).transfer(_stakedUserToken.userAddress, withdrawTokenValue), "TS:U");

        uint256 _poolId = _stakedUserToken.poolId;
        uint256 _value = _stakedUserToken.totalValueStake;
        uint256 _valueUsd = _stakedUserToken.totalValueStakeUsd;
        if (totalUserStakedPoolToken[msg.sender][_poolId] > _value) {
            totalUserStakedPoolToken[msg.sender][_poolId] = totalUserStakedPoolToken[msg.sender][_poolId] - _value;
        } else {
            totalUserStakedPoolToken[msg.sender][_poolId] = 0;
        }

        if (totalUserStakedPoolUsd[msg.sender][_poolId] > _valueUsd) {
            totalUserStakedPoolUsd[msg.sender][_poolId] = totalUserStakedPoolUsd[msg.sender][_poolId] - _valueUsd;
        } else {
            totalUserStakedPoolUsd[msg.sender][_poolId] = 0;
        }

        stakedToken[_stakeId].isWithdraw = true;

        if (stakeTokenPool.duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, _valueUsd, false);
        }

        emit Harvested(_stakeId);
    }

    function withdrawPool(uint256[] memory _stakeIds) external override {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            withdraw(_stakeIds[i]);
        }
    }

    function getRefClaimed(address _wallet) external view override returns (uint256) {
        return refClaimed[_wallet];
    }

    // Setting
    function setMaxFloor(uint16 _maxFloor) external override onlyOwner {
        maxFloor = _maxFloor;
    }

    function setTimeOpenStaking(uint256 _timeOpening) external override onlyOwner {
        timeOpenStaking = _timeOpening;
    }

    function setTokenDecimal(uint256 _tokenDecimal) external override onlyOwner {
        tokenDecimal = _tokenDecimal;
    }

    function setRankCommissionDuration(uint256 _rankCommissionDuration) external override onlyOwner {
        rankCommissionDuration = _rankCommissionDuration;
    }

    function setPoolDurationHasLimit(uint256 _poolDurationHasLimit) external override onlyOwner {
        poolDurationHasLimit = _poolDurationHasLimit;
    }

    function setCommissionCondition(uint16 _level, uint256 _conditionInUsd) external override onlyOwner {
        amountConditions[_level] = _conditionInUsd;
    }

    function setCommissionPercent(uint16 _level, uint256 _percent) external override onlyOwner {
        commissionPercents[_level] = _percent;
    }

    function setDirectCommissionPercents(uint256 _poolId, uint256 _percent) external override onlyOwner {
        directCommissionPercents[_poolId] = _percent;
    }

    function setCanNotWithdraw(uint256 _stakedTokenId, uint256 _canNotWithdraw) external override onlyOwner {
        canNotWithdraw[_stakedTokenId] = _canNotWithdraw;
    }

    // Set contract
    function setNovaxToken(address _novaxToken) external override onlyOwner {
        novaxToken = _novaxToken;
    }

    function setApyContract(address _tokenStakeApy) external override onlyOwner {
        tokenStakeApy = _tokenStakeApy;
    }

    function setMarketContract(address _marketContract) external override onlyOwner {
        marketplaceContract = _marketContract;
    }

    function setRankingContract(address _rankingContract) external override onlyOwner {
        rankingContract = _rankingContract;
    }

    function setOracleContract(address _token, address _oracleContract) external override onlyOwner {
        oracleContracts[_token] = _oracleContract;
    }

    // Migrate
    function setStakeTokenPool(uint256 _poolId, uint256 _maxStakePerWallet, uint256 _duration, bool _isPayProfit, address _stakeToken, address _earnToken) external override onlyOwner {
        stakeTokenPools[_poolId].poolId = _poolId;
        stakeTokenPools[_poolId].maxStakePerWallet = _maxStakePerWallet;
        stakeTokenPools[_poolId].duration = _duration;
        stakeTokenPools[_poolId].isPayProfit = _isPayProfit;
        stakeTokenPools[_poolId].stakeToken = _stakeToken;
        stakeTokenPools[_poolId].earnToken = _earnToken;
        uint256 _index = _poolId + 1;
        if (_index > stakeTokenPoolLength) {
            stakeTokenPoolLength = _index;
        }
    }

    function setStakedToken(
        uint256 _stakeId,
        uint256 _poolId,
        address _userAddress,
        uint256 _startTime,
        uint256 _unlockTime,
        uint256 _totalValueStake,
        uint256 _totalValueStakeUsd,
        uint256 _totalValueClaimed,
        uint256 _totalValueClaimedUsd,
        bool _isWithdraw
    ) external override onlyOwner {
        stakedToken[_stakeId].stakeId = _stakeId;
        stakedToken[_stakeId].poolId = _poolId;
        stakedToken[_stakeId].userAddress = _userAddress;
        stakedToken[_stakeId].startTime = _startTime;
        stakedToken[_stakeId].unlockTime = _unlockTime;
        stakedToken[_stakeId].totalValueStake = _totalValueStake;
        stakedToken[_stakeId].totalValueStakeUsd = _totalValueStakeUsd;
        stakedToken[_stakeId].totalValueClaimed = _totalValueClaimed;
        stakedToken[_stakeId].totalValueClaimedUsd = _totalValueClaimedUsd;
        stakedToken[_stakeId].isWithdraw = _isWithdraw;
    }

    function setIndexData(uint256 _stakeTokenPoolLength, uint256 _stakeIndex) external override onlyOwner {
        stakeTokenPoolLength = _stakeTokenPoolLength;
        stakeIndex = _stakeIndex;
    }

    function setDirectCommission(address[] calldata _wallets, uint256[] calldata _directCommissions) external override onlyOwner {
        require(_wallets.length == _directCommissions.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            directCommission[_wallets[index]] = _directCommissions[index];
        }
    }

    function setRefClaimed(address[] calldata _wallets, uint256[] calldata _refClaimeds) external override onlyOwner {
        require(_wallets.length == _refClaimeds.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            refClaimed[_wallets[index]] = _refClaimeds[index];
        }
    }

    function setUserStakedPoolToken(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolTokens) external override onlyOwner {
        require(_wallets.length == _poolIds.length && _wallets.length == _totalUserStakedPoolTokens.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            totalUserStakedPoolToken[_wallets[index]][_poolIds[index]] = _totalUserStakedPoolTokens[index];
        }
    }

    function setUserStakedPoolUsd(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolUsds) external override onlyOwner {
        require(_wallets.length == _poolIds.length && _wallets.length == _totalUserStakedPoolUsds.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            totalUserStakedPoolUsd[_wallets[index]][_poolIds[index]] = _totalUserStakedPoolUsds[index];
        }
    }

    // Admin
    function addStakedToken(uint256 _poolId, address _userAddress, uint256 _totalValueStake, bool _payDirect) external override onlyOwner {
        uint256 totalUserStakePool = totalUserStakedPoolToken[_userAddress][_poolId] + _totalValueStake;

        require(stakeTokenPools[_poolId].maxStakePerWallet == 0 || stakeTokenPools[_poolId].maxStakePerWallet >= totalUserStakePool, "TS:M");
        uint256 poolDuration = stakeTokenPools[_poolId].duration;
        uint256 unlockTimeEstimate = poolDuration == 0 ? 0 : (block.timestamp + (2592000 * poolDuration));
        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        uint256 stakeValueUsd = tokenToUsd(stakeToken, _totalValueStake);

        stakeIndex = stakeIndex + 1;
        stakedToken[stakeIndex].stakeId = stakeIndex;
        stakedToken[stakeIndex].poolId = _poolId;
        stakedToken[stakeIndex].userAddress = _userAddress;
        stakedToken[stakeIndex].startTime = block.timestamp;
        stakedToken[stakeIndex].unlockTime = unlockTimeEstimate;
        stakedToken[stakeIndex].totalValueStake = _totalValueStake;
        stakedToken[stakeIndex].totalValueStakeUsd = stakeValueUsd;
        stakedToken[stakeIndex].isWithdraw = false;

        totalUserStakedPoolToken[_userAddress][_poolId] += _totalValueStake;
        totalUserStakedPoolUsd[_userAddress][_poolId] += stakeValueUsd;

        if (_payDirect) {
            payDirectCommission(_userAddress, _poolId, _totalValueStake);
        }

        if (stakeTokenPools[_poolId].duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, stakeValueUsd, true);
        }

        emit Staked(stakeIndex, _poolId, _userAddress, _totalValueStake, block.timestamp, unlockTimeEstimate);
    }

    // Withdraw token
    function recoverLostBNB() external override onlyOwner {
        address payable recipient = payable(msg.sender);
        recipient.transfer(address(this).balance);
    }

    function withdrawTokenEmergency(address _token, uint256 _amount) external override onlyOwner {
        require(_amount > 0, "TS:I");
        IERC20(_token).transfer(msg.sender, _amount);
    }
}
