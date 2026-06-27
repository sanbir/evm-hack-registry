// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

/**
 * @title Pawnfi's ApeStakingStorage Contract
 * @author Pawnfi
 */
abstract contract ApeStakingStorage {
    uint256 internal constant BASE_PERCENTS = 1e18;
    uint256 internal constant BLOCKS_PER_YEAR = 2102400;
    uint256 internal constant APECOIN_POOL_ID = 0;
    uint256 internal constant BAYC_POOL_ID = 1;
    uint256 internal constant MAYC_POOL_ID = 2;
    uint256 internal constant BAKC_POOL_ID = 3;

    address internal constant BAYC_ADDR = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal constant MAYC_ADDR = 0x60E4d786628Fea6478F785A6d7e704777c86a7c6;
    address internal constant BAKC_ADDR = 0xba30E5F9Bb24caa003E9f2f0497Ad287FDF95623;

    // keccak256("REINVEST_ROLE")
    bytes32 internal constant REINVEST_ROLE = 0xd93ff0403c1db5bd4fbb77a795131f2a70890eb98caff8a0284dcba25677aeb2;

    /// @notice ApeCoinStaking address
    address public apeCoinStaking;

    /// @notice ApeCoin address
    address public apeCoin;

    /// @notice ApePool address
    address public apePool;

    /// @notice nftGateway address
    address public nftGateway;

    /// @notice PawnToken address
    address public pawnToken;

    /// @notice P-BAYC address
    address public pbaycAddr;

    /// @notice P-MAYC address
    address public pmaycAddr;

    /// @notice P-BAKC address
    address public pbakcAddr;

    /// @notice Fee address
    address public feeTo;

    /**
     * @notice Contract configuration info
     * @member addMinStakingRate Staking rate threshold
     * @member liquidateRate Safety threshold
     * @member borrowSafeRate Suspension rate
     * @member liquidatePawnAmount PAWN reward for triggering suspension
     * @member feeRate Reinvestment fee
     */
    struct StakingConfiguration {
        uint256 addMinStakingRate;
        uint256 liquidateRate;
        uint256 borrowSafeRate;
        uint256 liquidatePawnAmount;
        uint256 feeRate;
    }

    /// @notice Get contract configuration info
    StakingConfiguration public stakingConfiguration;

    /**
     * @notice User info
     * @member collectRate Collect rate
     * @member stakeAmount APE staked amount in each pool
     * @member iTokenAmount Amount of iToken received upon deposit in each pool
     * @member stakeIds NFT IDs in each staking pool
     * @member depositIds NFT IDs deposited in each pool
     */
    struct UserInfo {
        uint256 collectRate;

        mapping(uint256 => uint256) stakeAmount;

        mapping(uint256 => uint256) iTokenAmount;

        mapping(uint256 => EnumerableSetUpgradeable.UintSet) stakeIds;

        mapping(uint256 => EnumerableSetUpgradeable.UintSet) depositIds;
    }

    // Store user information.
    mapping(address => UserInfo) internal _userInfo;

    /**
     * @notice Nft info 
     * @member poolId Pool id
     * @member stakeIds All staked NFT IDs
     * @member staker nft id Corresponding staker
     * @member depositor nft id Corresponding supplier
     * @member iTokenAmount nft id Corresponding iToken amount
     */
    struct NftInfo {
        uint256 poolId;

        EnumerableSetUpgradeable.UintSet stakeIds;

        mapping(uint256 => address) staker;

        mapping(uint256 => address) depositor;

        mapping(uint256 => uint256) iTokenAmount;        
    }

    // Store NFT info
    mapping(address => NftInfo) internal _nftInfo;

    struct StakingInfo {
        address nftAsset;
        uint256 cashAmount;
        uint256 borrowAmount;
    }

    struct DepositInfo {
        uint256[] mainTokenIds;
        uint256[] bakcTokenIds;
    }
    
    enum RewardAction {
        CLAIM, // User claims reward
        WITHDRAW, // User withdraws staked principal (user remains OWNER)
        REDEEM,// After consignment or leverage default, user is no longer OWNER; when user actively withdraws staked principal to stop staking, unclaimed rewards are not returned
        RESTAKE,// Reinvest
        STOPSTAKE,// Health factor issue, suspend staking
        ONWITHDRAW,// NFT's OWNER changes, terminate user staking (consignment/leverage redemption, purchase during consignment, withdrawal from lending market, NFT liquidation)
        ONREDEEM // After consignment or leverage default, user is no longer OWNER, acquired by others, only returning staked principal
    }

    event DepositNftToStake(address userAddr, address nftAsset, uint256[] nftIds, uint256 iTokenAmount, uint256 ptokenAmount);
    event WithdrawNftFromStake(address userAddr, address nftAsset, uint256 nftId, uint256 iTokenAmount, uint256 ptokenAmount);

    event StakeSingleNft(address userAddr, address nftAsset, uint256 nftId, uint256 amount);
    event UnstakeSingleNft(address userAddr, address nftAsset, uint256 nftId, uint256 amount, uint256 rewardAmount);
    event ClaimSingleNft(address userAddr, address nftAsset, uint256 nftId, uint256 rewardAmount);

    event StakePairNft(address userAddr, address nftAsset, uint256 mainTokenId, uint256 bakcTokenId, uint256 amount);
    event UnstakePairNft(address userAddr, address nftAsset, uint256 mainTokenId, uint256 bakcTokenId, uint256 amount, uint256 rewardAmount);
    event ClaimPairNft(address userAddr, address nftAsset, uint256 mainTokenId, uint256 bakcTokenId, uint256 rewardAmount);
    
    event SetCollectRate(address userAddr, uint256 collectRate);
 }