// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "../data/StructData.sol";

interface IStaking {
    event Staked(uint256 id, address indexed staker, uint256 indexed nftID, uint256 unlockTime);
    event Unstaked(uint256 id, address indexed staker, uint256 indexed nftID);
    event Claimed(uint256 id, address indexed staker, uint256 claimAmount);

    function getCommissionCondition(uint8 _level) external view returns (uint32);

    function getCommissionPercent(uint8 _level) external view returns (uint16);

    function getTotalTeamInvestment(address _wallet) external view returns (uint256);

    function getRefStakingValue(address _wallet) external view returns (uint256);

    function getUserStakingNfts(address _wallet) external view returns (uint256[] memory);

    function stake(uint256 _nftId, bytes memory _data) external;

    function getTeamStakingValue(address _wallet) external view returns (uint256);

    function getStakingCommissionEarned(address _wallet) external view returns (uint256);

    function getTimeClaimEarn() external view returns (uint256);

    function unstake(uint256 _stakeId, bytes memory data) external;

    function claim(uint256 _stakeId) external;

    function claimAll(uint256[] memory _stakeIds) external;

    function getDetailOfStake(uint256 _stakeId) external view returns (StructData.StakedNFT memory);

    function possibleUnstake(uint256 _stakeId) external view returns (bool);

    function claimableForStakeInTokenWithDecimal(uint256 _nftId) external view returns (uint256);

    function earnableForStakeWithDecimal(uint256 _nftId) external view returns (uint256);

    function getTotalStakeAmountUSD(address _staker) external view returns (uint256);

    function possibleForCommission(address _staker, uint8 _level) external view returns (bool);

    function getMaxFloorProfit(address _user) external view returns (uint8);

    function getUserCommissionCanEarnUsdWithDecimal(address _user, uint256 _totalCommissionInUsdDecimal) external view returns (uint256);

    function getCommissionProfitUnclaim(address _user) external view returns (uint256);

    function getSaleAddresses() external view returns (address[] memory);

    function checkUserIsSaleAddress(address _user) external view returns (bool);
}
