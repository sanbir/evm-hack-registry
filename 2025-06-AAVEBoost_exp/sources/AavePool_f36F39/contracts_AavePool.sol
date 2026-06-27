//SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IAaveGovernanceV2} from "./interfaces/Aave/IAaveGovernanceV2.sol";
import {IGovernanceStrategy} from "./interfaces/Aave/IGovernanceStrategy.sol";
import {IExecutorWithTimelock} from "./interfaces/Aave/IExecutorWithTimelock.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IWrapperToken.sol";
import "./interfaces/Aave/IStakedAave.sol";
import "./interfaces/IERC20Details.sol";
import "./interfaces/IBribeExecutor.sol";
import "./BribePoolBase.sol";

////////////////////////////////////////////////////////////////////////////////////////////
///
/// @title AavePool
/// @author contact@bribe.xyz
/// @notice
///
////////////////////////////////////////////////////////////////////////////////////////////

contract AavePool is BribePoolBase, IAavePool, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev share scale
    uint256 private constant SHARE_SCALE = 1e12;

    /// @dev maximum claim iterations
    uint64 internal constant MAX_CLAIM_ITERATIONS = 10;

    /// @dev fee precision
    uint64 internal constant FEE_PRECISION = 10000;

    /// @dev fee percentage share is 16%
    uint128 internal constant FEE_PERCENTAGE = 1600;

    /// @dev seconds per block
    uint64 internal constant secondPerBlock = 13;

    /// @dev aave governance
    IAaveGovernanceV2 public immutable aaveGovernance;

    /// @dev bidders will bid with bidAsset e.g. usdc
    IERC20 public immutable bidAsset;

    /// @dev bribe token
    IERC20 public immutable bribeToken;

    /// @dev aave token
    IERC20 public immutable aaveToken;

    /// @dev stkAave token
    IERC20 public immutable stkAaveToken;

    /// @dev aave wrapper token
    IWrapperToken public immutable wrapperAaveToken;

    /// @dev stkAave wrapper token
    IWrapperToken public immutable wrapperStkAaveToken;

    /// @dev feeReceipient address to send received fees to
    address public feeReceipient;

    /// @dev pending rewards to be distributed
    uint128 internal pendingRewardToBeDistributed;

    /// @dev fees received
    uint128 public feesReceived;

    /// @dev asset index
    AssetIndex public assetIndex;

    /// @dev bribre reward config
    BribeReward public bribeRewardConfig;

    /// @dev bid id to bid information
    mapping(uint256 => Bid) public bids;

    /// @dev blocked proposals
    mapping(uint256 => bool) public blockedProposals;

    /// @dev proposal id to bid information
    mapping(uint256 => uint256) internal bidIdToProposalId;

    /// @dev user info
    mapping(address => UserInfo) internal users;

    constructor(
        address bribeToken_,
        address aaveToken_,
        address stkAaveToken_,
        address bidAsset_,
        address aave_,
        address feeReceipient_,
        IWrapperToken wrapperAaveToken_,
        IWrapperToken wrapperStkAaveToken_,
        BribeReward memory rewardConfig_
    ) BribePoolBase() {
        require(bribeToken_ != address(0), "BRIBE_TOKEN");
        require(aaveToken_ != address(0), "AAVE_TOKEN");
        require(stkAaveToken_ != address(0), "STKAAVE_TOKEN");
        require(aave_ != address(0), "AAVE_GOVERNANCE");
        require(address(bidAsset_) != address(0), "BID_ASSET");
        require(feeReceipient_ != address(0), "FEE_RECEIPIENT");
        require(address(wrapperAaveToken_) != address(0), "AAVE_WRAPPER");
        require(address(wrapperStkAaveToken_) != address(0), "STK_WRAPPER");

        bribeToken = IERC20(bribeToken_);
        aaveToken = IERC20(aaveToken_);
        stkAaveToken = IERC20(stkAaveToken_);
        aaveGovernance = IAaveGovernanceV2(aave_);
        bidAsset = IERC20(bidAsset_);
        bribeRewardConfig = rewardConfig_;
        feeReceipient = feeReceipient_;

        // initialize wrapper tokens
        wrapperAaveToken_.initialize(aaveToken_);
        wrapperStkAaveToken_.initialize(stkAaveToken_);

        wrapperAaveToken = wrapperAaveToken_;
        wrapperStkAaveToken = wrapperStkAaveToken_;
    }

    /// @notice deposit
    /// @param asset either Aave or stkAave
    /// @param recipient address to mint the receipt tokens
    /// @param amount amount of tokens to deposit
    /// @param claim claim stk aave rewards from Aave
    function deposit(
        IERC20 asset,
        address recipient,
        uint128 amount,
        bool claim
    ) external override whenNotPaused nonReentrant {
        if (asset == aaveToken) {
            _deposit(asset, wrapperAaveToken, recipient, amount, claim);
        } else {
            _deposit(stkAaveToken, wrapperStkAaveToken, recipient, amount, claim);
        }
    }

    /// @notice withdraw
    /// @param asset either Aave or stkAave
    /// @param recipient address to mint the receipt tokens
    /// @param amount amount of tokens to deposit
    /// @param claim claim stk aave rewards from Aave
    function withdraw(
        IERC20 asset,
        address recipient,
        uint128 amount,
        bool claim
    ) external override nonReentrant {
        if (asset == aaveToken) {
            _withdraw(asset, wrapperAaveToken, recipient, amount, claim);
        } else {
            _withdraw(stkAaveToken, wrapperStkAaveToken, recipient, amount, claim);
        }
    }

    /// @dev vote to `proposalId` with `support` option
    /// @param proposalId proposal id
    function vote(uint256 proposalId) external nonReentrant {
        Bid storage currentBid = bids[proposalId];

        require(currentBid.endTime > 0, "INVALID_PROPOSAL");
        require(currentBid.endTime < block.timestamp, "BID_ACTIVE");

        distributeRewards(proposalId);

        IAaveGovernanceV2(aaveGovernance).submitVote(proposalId, currentBid.support);

        emit Vote(proposalId, msg.sender, currentBid.support, block.timestamp);
    }

    /// @dev place a bid after check AaveGovernance status
    /// @param bidder bidder address
    /// @param proposalId proposal id
    /// @param amount amount of bid assets
    /// @param support the suport for the proposal
    function bid(
        address bidder,
        uint256 proposalId,
        uint128 amount,
        bool support
    ) external override whenNotPaused nonReentrant {
        IAaveGovernanceV2.ProposalState state = IAaveGovernanceV2(aaveGovernance).getProposalState(
            proposalId
        );
        require(
            state == IAaveGovernanceV2.ProposalState.Pending ||
                state == IAaveGovernanceV2.ProposalState.Active,
            "INVALID_PROPOSAL_STATE"
        );

        require(blockedProposals[proposalId] == false, "PROPOSAL_BLOCKED");

        Bid storage currentBid = bids[proposalId];
        address prevHighestBidder = currentBid.highestBidder;
        uint128 currentHighestBid = currentBid.highestBid;
        uint128 newHighestBid;

        // new bid
        if (prevHighestBidder == address(0)) {
            uint64 endTime = uint64(_getAuctionExpiration(proposalId));
            currentBid.endTime = endTime;
            currentBid.totalVotes = votingPower(proposalId);
            currentBid.proposalStartBlock = IAaveGovernanceV2(aaveGovernance)
                .getProposalById(proposalId)
                .startBlock;
        }

        require(currentBid.endTime > block.timestamp, "BID_ENDED");
        require(currentBid.totalVotes > 0, "INVALID_VOTING_POWER");

        // if bidder == currentHighestBidder increase the bid amount
        if (prevHighestBidder == bidder) {
            bidAsset.safeTransferFrom(msg.sender, address(this), amount);

            newHighestBid = currentHighestBid + amount;
        } else {
            require(amount > currentHighestBid, "LOW_BID");

            bidAsset.safeTransferFrom(msg.sender, address(this), amount);

            // refund to previous highest bidder
            if (prevHighestBidder != address(0)) {
                pendingRewardToBeDistributed -= currentHighestBid;
                bidAsset.safeTransfer(prevHighestBidder, currentHighestBid);
            }

            newHighestBid = amount;
        }

        // write the new bid info to storage
        pendingRewardToBeDistributed += amount;
        currentBid.highestBid = newHighestBid;
        currentBid.support = support;
        currentBid.highestBidder = bidder;

        emit HighestBidIncreased(
            proposalId,
            prevHighestBidder,
            bidder,
            msg.sender,
            newHighestBid,
            support
        );
    }

    /// @dev refund bid for a cancelled proposal ONLY if it was not voted on
    /// @param proposalId proposal id
    function refund(uint256 proposalId) external nonReentrant {
        IAaveGovernanceV2.ProposalState state = IAaveGovernanceV2(aaveGovernance).getProposalState(
            proposalId
        );

        require(state == IAaveGovernanceV2.ProposalState.Canceled, "PROPOSAL_ACTIVE");

        Bid storage currentBid = bids[proposalId];
        uint128 highestBid = currentBid.highestBid;
        address highestBidder = currentBid.highestBidder;

        // we do not refund if no high bid or if the proposal has been voted on
        if (highestBid == 0 || currentBid.voted) return;

        // reset the bid proposal state
        delete bids[proposalId];

        // refund the bid money
        pendingRewardToBeDistributed -= highestBid;
        bidAsset.safeTransfer(highestBidder, highestBid);

        emit Refund(proposalId, highestBidder, highestBid);
    }

    /// @dev distribute rewards for the proposal
    /// @notice called in children's vote function (after bidding process ended)
    /// @param proposalId id of proposal to distribute rewards fo
    function distributeRewards(uint256 proposalId) public {
        Bid storage currentBid = bids[proposalId];

        // ensure that the bidding period has ended
        require(block.timestamp > currentBid.endTime, "BID_ACTIVE");

        if (currentBid.voted) return;

        uint128 highestBid = currentBid.highestBid;
        uint128 feeAmount = _calculateFeeAmount(highestBid);

        // reduce pending reward
        pendingRewardToBeDistributed -= highestBid;
        assetIndex.bidIndex += (highestBid - feeAmount);
        feesReceived += feeAmount;
        currentBid.voted = true;
        // rewrite the highest bid minus fee
        // set and increase the bid id
        bidIdToProposalId[assetIndex.bidId] = proposalId;
        assetIndex.bidId += 1;

        emit RewardDistributed(proposalId, highestBid);
    }

    /// @dev withdrawFees withdraw fees
    /// Enables ONLY the fee receipient to withdraw the pool accrued fees
    function withdrawFees() external override nonReentrant returns (uint256 feeAmount) {
        require(msg.sender == feeReceipient, "ONLY_RECEIPIENT");

        feeAmount = feesReceived;

        if (feeAmount > 0) {
            feesReceived = 0;
            bidAsset.safeTransfer(feeReceipient, feeAmount);
        }

        emit WithdrawFees(address(this), feeAmount, block.timestamp);
    }

    /// @dev get reward amount for user specified by `user`
    /// @param user address of user to check balance of
    function rewardBalanceOf(address user)
        external
        view
        returns (
            uint256 totalPendingBidReward,
            uint256 totalPendingStkAaveReward,
            uint256 totalPendingBribeReward
        )
    {
        uint256 userAaveBalance = wrapperAaveToken.balanceOf(user);
        uint256 userStkAaveBalance = wrapperStkAaveToken.balanceOf(user);
        uint256 pendingBribeReward = _userPendingBribeReward(
            userAaveBalance + userStkAaveBalance,
            users[user].bribeLastRewardPerShare,
            _calculateBribeRewardPerShare(_calculateBribeRewardIndex())
        );

        uint256 pendingBidReward;

        uint256 currentBidRewardCount = assetIndex.bidId;

        if (userAaveBalance > 0) {
            pendingBidReward += _calculateUserPendingBidRewards(
                wrapperAaveToken,
                user,
                users[user].aaveLastBidId,
                currentBidRewardCount
            );
        }

        if (userStkAaveBalance > 0) {
            pendingBidReward += _calculateUserPendingBidRewards(
                wrapperStkAaveToken,
                user,
                users[user].stkAaveLastBidId,
                currentBidRewardCount
            );
        }

        totalPendingBidReward = users[user].totalPendingBidReward + pendingBidReward;
        (uint128 rewardsToReceive, ) = _stkAaveRewardsToReceive();

        totalPendingStkAaveReward =
            users[user].totalPendingStkAaveReward +
            _userPendingstkAaveRewards(
                user,
                users[user].stkAaveLastRewardPerShare,
                _calculateStkAaveRewardPerShare(rewardsToReceive),
                wrapperStkAaveToken
            );
        totalPendingBribeReward = users[user].totalPendingBribeReward + pendingBribeReward;
    }

    /// @dev claimReward for msg.sender
    /// @param to address to send the rewards to
    /// @param executor An external contract to call with
    /// @param data data to call the executor contract
    /// @param claim claim stk aave rewards from Aave
    function claimReward(
        address to,
        IBribeExecutor executor,
        bytes calldata data,
        bool claim
    ) external whenNotPaused nonReentrant {
        // accrue rewards for both stkAave and Aave token balances
        _accrueRewards(msg.sender, claim);

        UserInfo storage _currentUser = users[msg.sender];

        uint128 pendingBid = _currentUser.totalPendingBidReward;
        uint128 pendingStkAaveReward = _currentUser.totalPendingStkAaveReward;
        uint128 pendingBribeReward = _currentUser.totalPendingBribeReward;

        unchecked {
            // reset the reward calculation
            _currentUser.totalPendingBidReward = 0;
            _currentUser.totalPendingStkAaveReward = 0;
            // update lastStkAaveRewardBalance
            assetIndex.lastStkAaveRewardBalance -= pendingStkAaveReward;
        }

        if (pendingBid > 0) {
            bidAsset.safeTransfer(to, pendingBid);
        }

        if (pendingStkAaveReward > 0 && claim) {
            // claim stk aave rewards
            IStakedAave(address(stkAaveToken)).claimRewards(to, pendingStkAaveReward);
        }

        if (pendingBribeReward > 0 && bribeToken.balanceOf(address(this)) > pendingBribeReward) {
            _currentUser.totalPendingBribeReward = 0;

            if (address(executor) != address(0)) {
                bribeToken.safeTransfer(address(executor), pendingBribeReward);
                executor.execute(msg.sender, pendingBribeReward, data);
            } else {
                require(to != address(0), "INVALID_ADDRESS");
                bribeToken.safeTransfer(to, pendingBribeReward);
            }
        }

        emit RewardClaim(
            msg.sender,
            pendingBid,
            pendingStkAaveReward,
            pendingBribeReward,
            block.timestamp
        );
    }

    /// @dev block a proposalId from used in the pool
    /// @param proposalId proposalId
    function blockProposalId(uint256 proposalId) external onlyOwner {
        require(blockedProposals[proposalId] == false, "PROPOSAL_INACTIVE");
        Bid storage currentBid = bids[proposalId];

        // check if the propoal has already been voted on
        require(currentBid.voted == false, "BID_DISTRIBUTED");

        blockedProposals[proposalId] = true;

        uint128 highestBid = currentBid.highestBid;

        // check if the proposalId has any bids
        // if there is any current highest bidder
        // and the reward has not been distributed refund the bidder
        if (highestBid > 0) {
            pendingRewardToBeDistributed -= highestBid;
            address highestBidder = currentBid.highestBidder;
            // reset the bids
            delete bids[proposalId];
            bidAsset.safeTransfer(highestBidder, highestBid);
        }

        emit BlockProposalId(proposalId, block.timestamp);
    }

    /// @dev unblock a proposalId from used in the pool
    /// @param proposalId proposalId
    function unblockProposalId(uint256 proposalId) external onlyOwner {
        require(blockedProposals[proposalId] == true, "PROPOSAL_ACTIVE");

        blockedProposals[proposalId] = false;

        emit UnblockProposalId(proposalId, block.timestamp);
    }

    /// @dev returns the pool voting power for a proposal
    /// @param proposalId proposalId to fetch pool voting power
    function votingPower(uint256 proposalId) public view returns (uint256 power) {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = IAaveGovernanceV2(aaveGovernance)
            .getProposalById(proposalId);
        address governanceStrategy = IAaveGovernanceV2(aaveGovernance).getGovernanceStrategy();
        power = IGovernanceStrategy(governanceStrategy).getVotingPowerAt(
            address(this),
            proposal.startBlock
        );
    }

    /// @dev getPendingRewardToBeDistributed returns the pending reward to be distributed
    /// minus fees
    function getPendingRewardToBeDistributed() external view returns (uint256 pendingReward) {
        pendingReward =
            pendingRewardToBeDistributed -
            _calculateFeeAmount(pendingRewardToBeDistributed);
    }

    /// @notice pause pool actions
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice unpause pool actions
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice setFeeRecipient
    /// @param newReceipient new fee receipeitn
    function setFeeRecipient(address newReceipient) external onlyOwner {
        require(newReceipient != address(0), "INVALID_RECIPIENT");

        feeReceipient = newReceipient;

        emit UpdateFeeRecipient(address(this), newReceipient);
    }

    /// @notice setStartTimestamp
    /// @param startTimestamp when to start distributing rewards
    /// @param rewardPerSecond reward to distribute per second
    function setStartTimestamp(uint64 startTimestamp, uint128 rewardPerSecond) external onlyOwner {
        require(startTimestamp > block.timestamp, "INVALID_START_TIMESTAMP");
        if (bribeRewardConfig.endTimestamp != 0) {
            require(startTimestamp < bribeRewardConfig.endTimestamp, "HIGH_TIMESTAMP");
        }

        _updateBribeRewardIndex();

        uint64 oldTimestamp = bribeRewardConfig.startTimestamp;
        bribeRewardConfig.startTimestamp = startTimestamp;

        _setRewardPerSecond(rewardPerSecond);

        emit SetBribeRewardStartTimestamp(oldTimestamp, startTimestamp);
    }

    /// @notice setEndTimestamp
    /// @param endTimestamp end of bribe rewards
    function setEndTimestamp(uint64 endTimestamp) external onlyOwner {
        require(endTimestamp > block.timestamp, "INVALID_END_TIMESTAMP");
        require(endTimestamp > bribeRewardConfig.startTimestamp, "LOW_TIMESTAMP");

        _updateBribeRewardIndex();

        uint64 oldTimestamp = bribeRewardConfig.endTimestamp;
        bribeRewardConfig.endTimestamp = endTimestamp;

        emit SetBribeRewardEndTimestamp(oldTimestamp, endTimestamp);
    }

    /// @notice setEndTimestamp
    /// @param rewardPerSecond amount of rewards to distribute per second
    function setRewardPerSecond(uint128 rewardPerSecond) public onlyOwner {
        _updateBribeRewardIndex();
        _setRewardPerSecond(rewardPerSecond);
    }

    function _setRewardPerSecond(uint128 rewardPerSecond) internal {
        require(rewardPerSecond > 0, "INVALID_REWARD_SECOND");

        uint128 oldReward = bribeRewardConfig.rewardAmountDistributedPerSecond;

        bribeRewardConfig.rewardAmountDistributedPerSecond = rewardPerSecond;

        emit SetBribeRewardPerSecond(oldReward, rewardPerSecond);
    }

    /// @notice withdrawRemainingBribeReward
    /// @dev there is a 30 days window period after endTimestamp where a user can claim
    /// rewards before it can be reclaimed by Bribe
    function withdrawRemainingBribeReward() external onlyOwner {
        require(bribeRewardConfig.endTimestamp != 0, "INVALID_END_TIMESTAMP");
        require(block.timestamp > bribeRewardConfig.endTimestamp + 30 days, "GRACE_PERIOD");

        uint256 remaining = bribeToken.balanceOf(address(this));

        bribeToken.safeTransfer(address(this), remaining);

        emit WithdrawRemainingReward(remaining);
    }

    /// Create proposal on Aave
    /// @dev Creates a Proposal (needs to be validated by the Proposal Validator)
    /// @param executor The ExecutorWithTimelock contract that will execute the proposal
    /// @param targets list of contracts called by proposal's associated transactions
    /// @param values list of value in wei for each propoposal's associated transaction
    /// @param signatures list of function signatures (can be empty) to be used when created the callData
    /// @param calldatas list of calldatas: if associated signature empty, calldata ready, else calldata is arguments
    /// @param withDelegatecalls boolean, true = transaction delegatecalls the taget, else calls the target
    /// @param ipfsHash IPFS hash of the proposal
    function createProposal(
        IExecutorWithTimelock executor,
        address[] calldata targets,
        uint256[] calldata values,
        string[] calldata signatures,
        bytes[] calldata calldatas,
        bool[] calldata withDelegatecalls,
        bytes32 ipfsHash
    ) external onlyOwner returns (uint256 proposalId) {
        proposalId = aaveGovernance.create(
            executor,
            targets,
            values,
            signatures,
            calldatas,
            withDelegatecalls,
            ipfsHash
        );

        emit CreatedProposal(proposalId);
    }

    /// @dev  _calculateFeeAmount calculate the fee percentage share
    function _calculateFeeAmount(uint128 amount) internal pure returns (uint128 feeAmount) {
        feeAmount = (amount * FEE_PERCENTAGE) / FEE_PRECISION;
    }

    struct NewUserRewardInfoLocalVars {
        uint256 pendingBidReward;
        uint256 pendingstkAaveReward;
        uint256 pendingBribeReward;
        uint256 newUserAaveBidId;
        uint256 newUserStAaveBidId;
    }

    /// @dev _accrueRewards accrue rewards for an address
    /// @param user address to accrue rewards for
    /// @param claim claim pending stk aave rewards
    function _accrueRewards(address user, bool claim) internal {
        require(user != address(0), "INVALID_ADDRESS");

        UserInfo storage _user = users[user];

        NewUserRewardInfoLocalVars memory userRewardVars;

        uint256 userAaveBalance = wrapperAaveToken.balanceOf(user);
        uint256 userStkAaveBalance = wrapperStkAaveToken.balanceOf(user);
        uint256 total = userAaveBalance + userStkAaveBalance;

        // update bribe reward index
        _updateBribeRewardIndex();

        if (total > 0) {
            // calculate updated bribe rewards
            userRewardVars.pendingBribeReward = _userPendingBribeReward(
                total,
                _user.bribeLastRewardPerShare,
                assetIndex.bribeRewardPerShare
            );
        }

        if (userAaveBalance > 0) {
            // calculate pendingBidRewards
            uint256 reward;
            (userRewardVars.newUserAaveBidId, reward) = _userPendingBidRewards(
                assetIndex.bidIndex,
                wrapperAaveToken,
                user,
                users[user].aaveLastBidId
            );
            userRewardVars.pendingBidReward += reward;
        }

        if (claim) {
            _updateStkAaveStakeReward();
        }

        if (userStkAaveBalance > 0) {
            // calculate pendingBidRewards
            uint256 reward;
            (userRewardVars.newUserStAaveBidId, reward) = _userPendingBidRewards(
                assetIndex.bidIndex,
                wrapperStkAaveToken,
                user,
                users[user].stkAaveLastBidId
            );
            userRewardVars.pendingBidReward += reward;

            // distribute stkAaveTokenRewards to the user too
            userRewardVars.pendingstkAaveReward = _userPendingstkAaveRewards(
                user,
                users[user].stkAaveLastRewardPerShare,
                assetIndex.stkAaveRewardPerShare,
                wrapperStkAaveToken
            );
        }

        // write to storage
        _user.totalPendingBribeReward += userRewardVars.pendingBribeReward.toUint128();
        _user.totalPendingBidReward += userRewardVars.pendingBidReward.toUint128();
        _user.totalPendingStkAaveReward += userRewardVars.pendingstkAaveReward.toUint128();
        _user.stkAaveLastRewardPerShare = assetIndex.stkAaveRewardPerShare;
        _user.bribeLastRewardPerShare = assetIndex.bribeRewardPerShare;
        _user.aaveLastBidId = userRewardVars.newUserAaveBidId.toUint128();
        _user.stkAaveLastBidId = userRewardVars.newUserStAaveBidId.toUint128();

        emit RewardAccrue(
            user,
            userRewardVars.pendingBidReward,
            userRewardVars.pendingstkAaveReward,
            userRewardVars.pendingBribeReward,
            block.timestamp
        );
    }

    /// @dev deposit governance token
    /// @param asset asset to withdraw
    /// @param receiptToken asset wrapper token
    /// @param recipient address to award the receipt tokens
    /// @param amount amount to deposit
    /// @param claim claim pending stk aave rewards
    /// @notice emit {Deposit} event
    function _deposit(
        IERC20 asset,
        IWrapperToken receiptToken,
        address recipient,
        uint128 amount,
        bool claim
    ) internal {
        require(amount > 0, "INVALID_AMOUNT");

        // accrue user pending rewards
        _accrueRewards(recipient, claim);

        asset.safeTransferFrom(msg.sender, address(this), amount);

        // performs check that recipient != address(0)
        receiptToken.mint(recipient, amount);

        emit Deposit(asset, recipient, amount, block.timestamp);
    }

    /// @dev withdraw governance token
    /// @param asset asset to withdraw
    /// @param receiptToken asset wrapper token
    /// @param recipient address to award the receipt tokens
    /// @param amount amount to withdraw
    /// @param claim claim pending stk aave rewards
    function _withdraw(
        IERC20 asset,
        IWrapperToken receiptToken,
        address recipient,
        uint128 amount,
        bool claim
    ) internal {
        require(amount > 0, "INVALID_AMOUNT");
        require(receiptToken.balanceOf(msg.sender) >= amount, "INVALID_BALANCE");

        // claim pending bid rewards only
        _accrueRewards(msg.sender, claim);

        // burn tokens
        receiptToken.burn(msg.sender, amount);

        // send back tokens
        asset.safeTransfer(recipient, amount);

        emit Withdraw(asset, msg.sender, amount, block.timestamp);
    }

    /// @dev _calculateBribeRewardIndex
    function _calculateBribeRewardIndex() internal view returns (uint256 amount) {
        if (
            bribeRewardConfig.startTimestamp == 0 ||
            bribeRewardConfig.startTimestamp > block.timestamp
        ) return 0;

        uint64 startTimestamp = (bribeRewardConfig.startTimestamp >
            assetIndex.bribeLastRewardTimestamp)
            ? bribeRewardConfig.startTimestamp
            : assetIndex.bribeLastRewardTimestamp;

        uint256 endTimestamp;

        if (bribeRewardConfig.endTimestamp == 0) {
            endTimestamp = block.timestamp;
        } else {
            endTimestamp = block.timestamp > bribeRewardConfig.endTimestamp
                ? bribeRewardConfig.endTimestamp
                : block.timestamp;
        }

        if (endTimestamp > startTimestamp) {
            amount =
                (endTimestamp - startTimestamp) *
                bribeRewardConfig.rewardAmountDistributedPerSecond;
        }
    }

    /// @dev _updateBribeRewardIndex
    function _updateBribeRewardIndex() internal {
        uint256 newRewardAmount = _calculateBribeRewardIndex();

        assetIndex.bribeLastRewardTimestamp = block.timestamp.toUint64();
        assetIndex.bribeRewardIndex += newRewardAmount.toUint128();
        assetIndex.bribeRewardPerShare = _calculateBribeRewardPerShare(newRewardAmount).toUint128();

        emit AssetReward(bribeToken, assetIndex.bribeRewardIndex, block.timestamp);
    }

    /// @dev _calculateBribeRewardPerShare
    /// @param newRewardAmount additional reward
    function _calculateBribeRewardPerShare(uint256 newRewardAmount)
        internal
        view
        returns (uint256 newBribeRewardPerShare)
    {
        uint256 increaseSharePrice;
        if (newRewardAmount > 0) {
            increaseSharePrice = ((newRewardAmount * SHARE_SCALE) / _totalSupply());
        }

        newBribeRewardPerShare = assetIndex.bribeRewardPerShare + increaseSharePrice;
    }

    /// @dev _userPendingBribeReward
    /// @param userBalance user aave + stkAave balance
    /// @param userLastPricePerShare user last price per share
    /// @param currentBribeRewardPerShare current reward per share
    function _userPendingBribeReward(
        uint256 userBalance,
        uint256 userLastPricePerShare,
        uint256 currentBribeRewardPerShare
    ) internal pure returns (uint256 pendingReward) {
        if (userBalance > 0 && currentBribeRewardPerShare > 0) {
            pendingReward = ((userBalance * (currentBribeRewardPerShare - userLastPricePerShare)) /
                SHARE_SCALE).toUint128();
        }
    }

    /// @dev _totalSupply current total supply of tokens
    function _totalSupply() internal view returns (uint256) {
        return wrapperAaveToken.totalSupply() + wrapperStkAaveToken.totalSupply();
    }

    /// @dev returns the user bid reward share
    /// @param receiptToken wrapper token
    /// @param user user
    /// @param userLastBidId user last bid id
    function _userPendingBidRewards(
        uint128 currentBidIndex,
        IWrapperToken receiptToken,
        address user,
        uint128 userLastBidId
    ) internal view returns (uint256 accrueBidId, uint256 totalPendingReward) {
        if (currentBidIndex == 0) return (0, 0);

        uint256 currentBidRewardCount = assetIndex.bidId;

        if (userLastBidId == currentBidRewardCount) return (currentBidRewardCount, 0);

        accrueBidId = (currentBidRewardCount - userLastBidId) <= MAX_CLAIM_ITERATIONS
            ? currentBidRewardCount
            : userLastBidId + MAX_CLAIM_ITERATIONS;

        totalPendingReward = _calculateUserPendingBidRewards(
            receiptToken,
            user,
            userLastBidId,
            accrueBidId
        );
    }

    /// @dev _calculateUserPendingBidRewards
    /// @param receiptToken wrapper token
    /// @param user user
    /// @param userLastBidId user last bid id
    /// @param maxRewardId maximum bid id to accrue rewards to
    function _calculateUserPendingBidRewards(
        IWrapperToken receiptToken,
        address user,
        uint256 userLastBidId,
        uint256 maxRewardId
    ) internal view returns (uint256 totalPendingReward) {
        for (uint256 i = userLastBidId; i < maxRewardId; i++) {
            uint256 proposalId = bidIdToProposalId[i];
            Bid storage _bid = bids[proposalId];
            uint128 highestBid = _bid.highestBid;
            // only calculate if highest bid is available and it has been distributed
            if (highestBid > 0 && _bid.voted) {
                uint256 amount = receiptToken.getDepositAt(user, _bid.proposalStartBlock);
                if (amount > 0) {
                    // subtract fee from highest bid
                    totalPendingReward +=
                        (amount * (highestBid - _calculateFeeAmount(highestBid))) /
                        _bid.totalVotes;
                }
            }
        }
    }

    /// @dev update the stkAAve aave reward index
    function _updateStkAaveStakeReward() internal {
        (uint128 rewardsToReceive, uint256 newBalance) = _stkAaveRewardsToReceive();
        if (rewardsToReceive == 0) return;

        assetIndex.rewardIndex += rewardsToReceive;
        assetIndex.stkAaveRewardPerShare = _calculateStkAaveRewardPerShare(rewardsToReceive);
        assetIndex.lastStkAaveRewardBalance = newBalance;

        emit AssetReward(aaveToken, assetIndex.rewardIndex, block.timestamp);
    }

    /// @dev _calculateStkAaveRewardPerShare
    /// @param rewardsToReceive amount of aave rewards to receive
    function _calculateStkAaveRewardPerShare(uint256 rewardsToReceive)
        internal
        view
        returns (uint128 newRewardPerShare)
    {
        uint256 increaseRewardSharePrice;
        if (rewardsToReceive > 0) {
            increaseRewardSharePrice = ((rewardsToReceive * SHARE_SCALE) /
                wrapperStkAaveToken.totalSupply());
        }

        newRewardPerShare = (assetIndex.stkAaveRewardPerShare + increaseRewardSharePrice)
            .toUint128();
    }

    /// @dev _stkAaveRewardsToReceive
    function _stkAaveRewardsToReceive()
        internal
        view
        returns (uint128 rewardsToReceive, uint256 newBalance)
    {
        newBalance = IStakedAave(address(stkAaveToken)).getTotalRewardsBalance(address(this));
        rewardsToReceive = newBalance.toUint128() - assetIndex.lastStkAaveRewardBalance.toUint128();
    }

    /// @dev get the user stkAave aave reward share
    /// @param user user address
    /// @param userLastPricePerShare userLastPricePerShare
    /// @param currentStkAaveRewardPerShare the latest reward per share
    /// @param receiptToken stak aave wrapper token
    function _userPendingstkAaveRewards(
        address user,
        uint128 userLastPricePerShare,
        uint128 currentStkAaveRewardPerShare,
        IWrapperToken receiptToken
    ) internal view returns (uint256 pendingReward) {
        uint256 userBalance = receiptToken.balanceOf(user);

        if (userBalance > 0 && currentStkAaveRewardPerShare > 0) {
            uint128 rewardDebt = ((userBalance * userLastPricePerShare) / SHARE_SCALE).toUint128();
            pendingReward = (((userBalance * currentStkAaveRewardPerShare) / SHARE_SCALE) -
                rewardDebt).toUint128();
        }
    }

    /// @dev get auction expiration of `proposalId`
    /// @param proposalId proposal id
    function _getAuctionExpiration(uint256 proposalId) internal view returns (uint256) {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = IAaveGovernanceV2(aaveGovernance)
            .getProposalById(proposalId);
        return block.timestamp + (proposal.endBlock - block.number) * secondPerBlock - 1 hours;
    }
}
