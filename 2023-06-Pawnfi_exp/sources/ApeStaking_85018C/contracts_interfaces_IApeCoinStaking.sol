// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface IApeCoinStaking {
    struct PairNft {
        uint128 mainTokenId;
        uint128 bakcTokenId;
    }

    struct PairNftDepositWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
    }

    struct SingleNft {
        uint32 tokenId;
        uint224 amount;
    }

    struct DashboardStake {
        uint256 poolId;
        uint256 tokenId;
        uint256 deposited;
        uint256 unclaimed;
        uint256 rewards24hr;
        DashboardPair pair;
    }

    struct DashboardPair {
        uint256 mainTokenId;
        uint256 mainTypePoolId;
    }

    struct PoolUI {
        uint256 poolId;
        uint256 stakedAmount;
        TimeRange currentTimeRange;
    }

    struct TimeRange {
        uint48 startTimestampHour;
        uint48 endTimestampHour;
        uint96 rewardsPerHour;
        uint96 capPerPosition;
    }

    struct PairNftWithdrawWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
        bool isUncommit;
    }
    /// @dev Per address amount and reward tracking
    struct Position {
        uint256 stakedAmount;
        int256 rewardsDebt;
    }
        /// @notice State for ApeCoin, BAYC, MAYC, and Pair Pools
    struct Pool {
        uint48 lastRewardedTimestampHour;
        uint16 lastRewardsRangeIndex;
        uint96 stakedAmount;
        uint96 accumulatedRewardsPerShare;
        TimeRange[] timeRanges;
    }
    function addressPosition(address)
        external
        view
        returns (uint256 stakedAmount, int256 rewardsDebt);

    function apeCoin() external view returns (address);

    function bakcToMain(uint256, uint256)
        external
        view
        returns (uint248 tokenId, bool isPaired);

    function claimApeCoin(address _recipient) external;

    function claimBAKC(
        PairNft[] memory _baycPairs,
        PairNft[] memory _maycPairs,
        address _recipient
    ) external;

    function claimBAYC(uint256[] memory _nfts, address _recipient) external;

    function claimMAYC(uint256[] memory _nfts, address _recipient) external;

    function claimSelfApeCoin() external;

    function claimSelfBAKC(
        PairNft[] memory _baycPairs,
        PairNft[] memory _maycPairs
    ) external;

    function claimSelfBAYC(uint256[] memory _nfts) external;

    function claimSelfMAYC(uint256[] memory _nfts) external;

    function depositApeCoin(uint256 _amount, address _recipient) external;

    function depositBAKC(
        PairNftDepositWithAmount[] memory _baycPairs,
        PairNftDepositWithAmount[] memory _maycPairs
    ) external;

    function depositBAYC(SingleNft[] memory _nfts) external;

    function depositMAYC(SingleNft[] memory _nfts) external;

    function depositSelfApeCoin(uint256 _amount) external;

    function getAllStakes(address _address)
        external
        view
        returns (DashboardStake[] memory);

    function getApeCoinStake(address _address)
        external
        view
        returns (DashboardStake memory);

    function getBakcStakes(address _address)
        external
        view
        returns (DashboardStake[] memory);

    function getBaycStakes(address _address)
        external
        view
        returns (DashboardStake[] memory);

    function getMaycStakes(address _address)
        external
        view
        returns (DashboardStake[] memory);

    function getPoolsUI()
        external
        view
        returns (
            PoolUI memory,
            PoolUI memory,
            PoolUI memory,
            PoolUI memory
        );

    function getSplitStakes(address _address)
        external
        view
        returns (DashboardStake[] memory);

    function getTimeRangeBy(uint256 _poolId, uint256 _index)
        external
        view
        returns (TimeRange memory);

    function mainToBakc(uint256, uint256)
        external
        view
        returns (uint248 tokenId, bool isPaired);

    function nftContracts(uint256) external view returns (address);

    function nftPosition(uint256, uint256)
        external
        view
        returns (uint256 stakedAmount, int256 rewardsDebt);

    function pendingRewards(
        uint256 _poolId,
        address _address,
        uint256 _tokenId
    ) external view returns (uint256);

    function pools(uint256)
        external
        view
        returns (
            uint48 lastRewardedTimestampHour,
            uint16 lastRewardsRangeIndex,
            uint96 stakedAmount,
            uint96 accumulatedRewardsPerShare
        );

    function removeLastTimeRange(uint256 _poolId) external;

    function renounceOwnership() external;

    function rewardsBy(
        uint256 _poolId,
        uint256 _from,
        uint256 _to
    ) external view returns (uint256, uint256);

    function stakedTotal(address _address) external view returns (uint256);

    function updatePool(uint256 _poolId) external;

    function withdrawApeCoin(uint256 _amount, address _recipient) external;

    function withdrawBAKC(
        PairNftWithdrawWithAmount[] memory _baycPairs,
        PairNftWithdrawWithAmount[] memory _maycPairs
    ) external;

    function withdrawBAYC(
        SingleNft[] memory _nfts,
        address _recipient
    ) external;

    function withdrawMAYC(
        SingleNft[] memory _nfts,
        address _recipient
    ) external;

    function withdrawSelfApeCoin(uint256 _amount) external;

    function withdrawSelfBAYC(SingleNft[] memory _nfts) external;

    function withdrawSelfMAYC(SingleNft[] memory _nfts) external;
}
