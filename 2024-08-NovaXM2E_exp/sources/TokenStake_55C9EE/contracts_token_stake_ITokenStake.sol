// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface ITokenStake {
    struct StakeTokenPools {
        uint256 poolId;
        uint256 maxStakePerWallet;
        uint256 duration;
        bool isPayProfit;
        address stakeToken;
        address earnToken;
    }

    struct StakedToken {
        uint256 stakeId;
        uint256 poolId;
        address userAddress;
        uint256 startTime;
        uint256 unlockTime;
        uint256 lastClaimTime;
        uint256 totalValueStake;
        uint256 totalValueStakeUsd;
        uint256 totalValueClaimed;
        uint256 totalValueClaimedUsd;
        bool isWithdraw;
    }

    event Staked(uint256 indexed id, uint256 poolId, address indexed staker, uint256 stakeValue, uint256 startTime, uint256 unlockTime);
    event Claimed(uint256 indexed id, address indexed staker, uint256 claimAmount);
    event Harvested(uint256 indexed id);

    function getCommissionPercent(uint16 _level) external view returns (uint256);

    function getCommissionCondition(uint16 _level) external view returns (uint256);

    function getStakeTokenPool(uint256 _poolId) external view returns (StakeTokenPools memory);

    function getTotalUserStakedToken(address _user) external returns (uint256);

    function getTotalUserStakedUsd(address _user) external returns (uint256);

    function getTotalUserWithdrawToken(address _user) external returns (uint256);

    function getTotalUserWithdrawUsd(address _user) external returns (uint256);

    function getTotalUserClaimedToken(address _user) external returns (uint256);

    function getTotalUserClaimedUsd(address _user) external returns (uint256);

    function getTotalUserStakedAvailableToken(address _user) external returns (uint256);

    function getTotalUserStakedAvailableUsd(address _user) external returns (uint256);

    function getUserStakedPoolToken(address _user, uint256 _poolId) external view returns (uint256);

    function getUserStakedPoolUsd(address _user, uint256 _poolId) external view returns (uint256);

    function getDirectCommission(address _user) external view returns (uint256);

    function getPoolTotalStakeToken(uint256 _poolId) external view returns (uint256);

    function getPoolTotalStakeUsd(uint256 _poolId) external view returns (uint256);

    function getPoolTotalClaimToken(uint256 _poolId) external view returns (uint256);

    function getPoolTotalClaimUsd(uint256 _poolId) external view returns (uint256);

    function totalStakedToken() external view returns (uint256);

    function totalStakedUsd() external view returns (uint256);

    function totalWithdrawToken() external view returns (uint256);

    function totalWithdrawUsd() external view returns (uint256);

    function totalClaimedToken() external view returns (uint256);

    function totalClaimedUsd() external view returns (uint256);

    function stake(uint256 _poolId, uint256 _stakeValue) external;

    function claimAll(uint256[] memory _poolIds) external;

    function claim(uint256 _poolId) external;

    function withdraw(uint256 _stakeId) external;

    function withdrawPool(uint256[] memory _stakeIds) external;

    function claimPool(uint256[] memory _stakeIds) external;

    function possibleForCommission(address _staker, uint16 _level) external view returns (bool);

    function calculateTokenEarnedStake(uint256 _stakeId) external view returns (uint256);

    function calculateUsdEarnedStake(uint256 _stakeId) external view returns (uint256);

    function calculateTokenEarnedMulti(uint256[] memory _stakeIds) external view returns (uint256);

    function getStakedToken(uint256 _stakeId) external view returns (StakedToken memory);

    function getTeamStakingValue(address _wallet) external view returns (uint256);

    function getRefClaimed(address _wallet) external view returns (uint256);
}
