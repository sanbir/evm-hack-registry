//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAavePool {
    struct AssetIndex {
        // tracks the last stkAave aave reward balance
        uint256 lastStkAaveRewardBalance;
        // tracks the total Aave reward for stkAave holders
        uint128 rewardIndex;
        // bribe reward index;
        uint128 bribeRewardIndex;
        // bribe reward last timestamp
        uint64 bribeLastRewardTimestamp;
        // bid id
        uint64 bidId;
        // tracks the total bid reward
        // share to be distributed
        uint128 bidIndex;
        // tracks the reward per share
        uint128 bribeRewardPerShare;
        // tracks the reward per share
        uint128 stkAaveRewardPerShare;
    }

    struct BribeReward {
        uint128 rewardAmountDistributedPerSecond;
        uint64 startTimestamp;
        uint64 endTimestamp;
    }

    struct UserInfo {
        // stkaave reward index
        uint128 stkAaveLastRewardPerShare;
        // bribe reward index
        uint128 bribeLastRewardPerShare;
        // reward from the bids in the bribe pool
        uint128 totalPendingBidReward;
        // tracks aave reward from the stk aave pool
        uint128 totalPendingStkAaveReward;
        // tracks bribe distributed to the user
        uint128 totalPendingBribeReward;
        // tracks the last user bid id for aave deposit
        uint128 aaveLastBidId;
        // tracks the last user bid id for stkAave deposit
        uint128 stkAaveLastBidId;
    }

    /// @dev proposal bid info
    struct Bid {
        uint256 totalVotes;
        uint256 proposalStartBlock;
        uint128 highestBid;
        uint64 endTime;
        bool support;
        bool voted;
        address highestBidder;
    }

    /// @dev emitted on deposit
    event Deposit(IERC20 indexed token, address indexed user, uint256 amount, uint256 timestamp);

    /// @dev emitted on user reward accrue
    event AssetReward(IERC20 indexed asset, uint256 totalAmountAccrued, uint256 timestamp);

    /// @dev emitted on user reward accrue
    event RewardAccrue(
        address indexed user,
        uint256 pendingBidReward,
        uint256 pendingStkAaveReward,
        uint256 pendingBribeReward,
        uint256 timestamp
    );

    event Withdraw(IERC20 indexed token, address indexed user, uint256 amount, uint256 timestamp);

    event RewardClaim(
        address indexed user,
        uint256 pendingBid,
        uint256 pendingReward,
        uint256 pendingBribeReward,
        uint256 timestamp
    );

    event RewardDistributed(uint256 proposalId, uint256 amount);

    event HighestBidIncreased(
        uint256 indexed proposalId,
        address indexed prevHighestBidder,
        address indexed highestBidder,
        address sender,
        uint256 highestBid,
        bool support
    );

    event BlockProposalId(uint256 indexed proposalId, uint256 timestamp);

    event UnblockProposalId(uint256 indexed proposalId, uint256 timestamp);

    event UpdateDelayPeriod(uint256 delayperiod, uint256 timestamp);

    /// @dev emitted on vote
    event Vote(uint256 indexed proposalId, address user, bool support, uint256 timestamp);

    /// @dev emitted on Refund
    event Refund(uint256 indexed proposalId, address bidder, uint256 bidAmount);

    /// @dev emitted on Unclaimed rewards
    event UnclaimedRewards(address owner, uint256 amount);

    /// @dev emitted on setEndTimestamp
    event SetBribeRewardEndTimestamp(uint256 oldTimestamp, uint256 endTimestamp);

    /// @dev emitted on setRewardPerSecond
    event SetBribeRewardPerSecond(uint256 oldRewardPerSecond, uint256 newRewardPerSecond);

    /// @dev emitted on withdrawRemainingReward
    event WithdrawRemainingReward(uint256 amount);

    /// @dev emmitted on setStartTimestamp
    event SetBribeRewardStartTimestamp(uint256 oldTimestamp, uint256 endTimestamp);

    /// @dev emitted on setFeeRecipient
    event UpdateFeeRecipient(address sender, address receipient);

    /// @dev emitted on createProposal
    event CreatedProposal(uint256 proposalId);

    function deposit(
        IERC20 asset,
        address recipient,
        uint128 amount,
        bool claim
    ) external;

    function withdraw(
        IERC20 asset,
        address recipient,
        uint128 amount,
        bool claim
    ) external;

    function bid(
        address bidder,
        uint256 proposalId,
        uint128 amount,
        bool support
    ) external;
}
