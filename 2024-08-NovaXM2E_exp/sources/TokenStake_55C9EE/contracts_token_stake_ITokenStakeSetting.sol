// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "../data/StructData.sol";

interface ITokenStakeSetting {
    function setRankCommissionDuration(uint256 _rankCommissionDuration) external;

    function setPoolDurationHasLimit(uint256 _poolDurationHasLimit) external;

    function setIndexData(uint256 _stakeTokenPoolLength, uint256 _stakeIndex) external;

    function setMaxFloor(uint16 _maxFloor) external;

    function setTokenDecimal(uint256 _tokenDecimal) external;

    function setRefClaimed(address[] calldata _wallets, uint256[] calldata _refClaimeds) external;

    function setDirectCommission(address[] calldata _wallets, uint256[] calldata _directCommissions) external;

    function setUserStakedPoolToken(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolTokens) external;

    function setUserStakedPoolUsd(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolUsds) external;

    function setDirectCommissionPercents(uint256 _poolId, uint256 _percent) external;

    function setCommissionPercent(uint16 _level, uint256 _percent) external;

    function setCommissionCondition(uint16 _level, uint256 _conditionInUsd) external;

    function setTimeOpenStaking(uint256 _timeOpening) external;

    function setCanNotWithdraw(uint256 _stakedTokenId, uint256 _canNotWithdraw) external;

    function setMarketContract(address _marketContract) external;

    function setNovaxToken(address _novaxToken) external;

    function setApyContract(address _tokenStakeApy) external;

    function setOracleContract(address _token, address _oracleContract) external;

    function setRankingContract(address _rankingContract) external;

    function setStakeTokenPool(uint256 _poolId, uint256 _maxStakePerWallet, uint256 _duration, bool _isPayProfit, address _stakeToken, address _earnToken) external;

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
    ) external;

    function addStakedToken(uint256 _poolId, address _userAddress, uint256 _totalValueStake, bool _payDirect) external;

    function recoverLostBNB() external;

    function withdrawTokenEmergency(address _token, uint256 _amount) external;
}
