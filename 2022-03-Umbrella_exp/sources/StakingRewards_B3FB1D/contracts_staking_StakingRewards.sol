//SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import "../interfaces/IStakingRewards.sol";
import "../interfaces/Pausable.sol";
import "../interfaces/RewardsDistributionRecipient.sol";
import "../interfaces/OnDemandToken.sol";
import "../interfaces/MintableToken.sol";

// based on synthetix
contract StakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct Times {
        uint32 periodFinish;
        uint32 rewardsDuration;
        uint32 lastUpdateTime;
        uint96 totalRewardsSupply;
    }

    // ========== STATE VARIABLES ========== //

    uint256 public immutable maxEverTotalRewards;

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;

    uint256 public rewardRate = 0;
    uint256 public rewardPerTokenStored;
    
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    Times public timeData;
    bool public stopped;

    // ========== EVENTS ========== //

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event FarmingFinished();

    // ========== MODIFIERS ========== //

    modifier whenActive() {
        require(!stopped, "farming is stopped");
        _;
    }

    modifier updateReward(address account) virtual {
        uint256 newRewardPerTokenStored = rewardPerToken();
        rewardPerTokenStored = newRewardPerTokenStored;
        timeData.lastUpdateTime = uint32(lastTimeRewardApplicable());

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = newRewardPerTokenStored;
        }

        _;
    }

    // ========== CONSTRUCTOR ========== //

    constructor(
        address _owner,
        address _rewardsDistribution,
        address _stakingToken,
        address _rewardsToken
    ) Owned(_owner) {
        require(OnDemandToken(_rewardsToken).ON_DEMAND_TOKEN(), "rewardsToken must be OnDemandToken");

        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        rewardsDistribution = _rewardsDistribution;

        timeData.rewardsDuration = 2592000; // 30 days
        maxEverTotalRewards = MintableToken(_rewardsToken).maxAllowedTotalSupply();
    }

    // ========== RESTRICTED FUNCTIONS ========== //

    function notifyRewardAmount(
        uint256 _reward
    ) override virtual external whenActive onlyRewardsDistribution updateReward(address(0)) {
        Times memory t = timeData;
        uint256 newRewardRate;

        if (block.timestamp >= t.periodFinish) {
            newRewardRate = _reward / t.rewardsDuration;
        } else {
            uint256 remaining = t.periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            newRewardRate = (_reward + leftover) / t.rewardsDuration;
        }

        require(newRewardRate != 0, "invalid rewardRate");

        rewardRate = newRewardRate;

        // always increasing by _reward even if notification is in a middle of period
        // because leftover is included
        uint256 totalRewardsSupply = timeData.totalRewardsSupply + _reward;
        require(totalRewardsSupply <= maxEverTotalRewards, "rewards overflow");

        timeData.totalRewardsSupply = uint96(totalRewardsSupply);
        timeData.lastUpdateTime = uint32(block.timestamp);
        timeData.periodFinish = uint32(block.timestamp + t.rewardsDuration);

        emit RewardAdded(_reward);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external whenActive onlyOwner {
        require(_rewardsDuration != 0, "empty _rewardsDuration");

        require(
            block.timestamp > timeData.periodFinish,
            "Previous period must be complete before changing the duration"
        );

        timeData.rewardsDuration = uint32(_rewardsDuration);
        emit RewardsDurationUpdated(_rewardsDuration);
    }

    // when farming was started with 1y and 12tokens
    // and we want to finish after 4 months, we need to end up with situation
    // like we were starting with 4mo and 4 tokens.
    function finishFarming() virtual external whenActive onlyOwner {
        Times memory t = timeData;
        require(block.timestamp < t.periodFinish, "can't stop if not started or already finished");

        stopped = true;

        if (_totalSupply != 0) {
            uint256 remaining = t.periodFinish - block.timestamp;
            timeData.rewardsDuration = uint32(t.rewardsDuration - remaining);
        }

        timeData.periodFinish = uint32(block.timestamp);

        emit FarmingFinished();
    }

    // ========== MUTATIVE FUNCTIONS ========== //

    function exit() override external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    function stake(uint256 amount) override external {
        _stake(msg.sender, amount, false);
    }

    function rescueToken(ERC20 _token, address _recipient, uint256 _amount) external onlyOwner() {
        if (address(_token) == address(stakingToken)) {
            require(_totalSupply <= stakingToken.balanceOf(address(this)) - _amount, "amount is too big to rescue");
        } else if (address(_token) == address(rewardsToken)) {
            revert("reward token can not be rescued");
        }

        _token.transfer(_recipient, _amount);
    }

    function periodFinish() external view returns (uint256) {
        return timeData.periodFinish;
    }

    function rewardsDuration() external view returns (uint256) {
        return timeData.rewardsDuration;
    }

    function lastUpdateTime() external view returns (uint256) {
        return timeData.lastUpdateTime;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function getRewardForDuration() override external view returns (uint256) {
        return rewardRate * timeData.rewardsDuration;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    function withdraw(uint256 amount) override public {
        _withdraw(amount, msg.sender, msg.sender);
    }

    function getReward() override public {
        _getReward(msg.sender, msg.sender);
    }

    // ========== VIEWS ========== //

    function totalSupply() override public view returns (uint256) {
        return _totalSupply;
    }

    function lastTimeRewardApplicable() override public view returns (uint256) {
        return Math.min(block.timestamp, timeData.periodFinish);
    }

    function rewardPerToken() override public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (
            (lastTimeRewardApplicable() - timeData.lastUpdateTime) * rewardRate * 1e18 / _totalSupply
        );
    }

    function earned(address account) override virtual public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18) + rewards[account];
    }

    function _stake(address user, uint256 amount, bool migration)
        internal
        nonReentrant
        notPaused
        updateReward(user)
    {
        require(timeData.periodFinish != 0, "Stake period not started yet");
        require(amount != 0, "Cannot stake 0");

        _totalSupply = _totalSupply + amount;
        _balances[user] = _balances[user] + amount;

        if (migration) {
            // other contract will send tokens to us, this will save ~13K gas
        } else {
            // not using safe transfer, because we working with trusted tokens
            require(stakingToken.transferFrom(user, address(this), amount), "token transfer failed");
        }

        emit Staked(user, amount);
    }

    /// @param amount tokens to withdraw
    /// @param user address
    /// @param recipient address, where to send tokens, if we migrating token address can be zero

    // VULNERABILITY: Unauthorized underflow-enabled withdrawal of staked tokens (no balance check + unchecked arithmetic in pre-0.8 Solidity)
    // 
    // Location: StakingRewards._withdraw (this file:258)
    // 
    // Detailed explanation:
    // - withdraw(uint256) at line 201 is public/override (from IStakingRewards) and callable by ANY address; it forwards to _withdraw(amount, msg.sender, msg.sender).
    // - _withdraw only enforces: require(amount != 0, "Cannot withdraw 0");  (no require(amount <= _balances[user]))
    // - Direct unchecked subtraction (Solidity 0.7.5 semantics): _totalSupply -= amount; _balances[user] -= amount;  (wraps on underflow; contrast with SafeERC20 and the SafeMath import used elsewhere).
    // - Comment at 260 is incorrect: "no way to overflow if stake tokens not overflow" — it ignores that a non-staker (or over-withdrawer) can supply arbitrary amount.
    // - The transfer (line 264) sends exactly the *supplied* amount (not clamped to actual stake), using the contract's real token balance.
    // - ReentrancyGuard and updateReward modifier do not help: nonReentrant protects the function, updateReward only reads/writes rewards based on *pre-subtraction* balance (0 for attacker).
    // - _stake at 241-249 has symmetric direct += but at least requires amount!=0 and does transferFrom before crediting (but no max supply etc.).
    // 
    // Code references:
    //   line 201: function withdraw(uint256 amount) override public { _withdraw(amount, msg.sender, msg.sender); }
    //   lines 258-265: the _withdraw body shown below
    //   lines 241-243 (stake): _totalSupply = _totalSupply + amount; _balances[user] = _balances[user] + amount;
    //   lines 220,225: rewardPerToken and earned depend on _totalSupply / _balances (corrupted post-attack)
    //   line 169 (rescue): uses _totalSupply in check (would also be affected by underflow corruption)
    // 
    // EXPLOIT STEPS (as demonstrated by 2022-03-Umbrella PoC in test/Umbrella_exp.sol and test/Umbrella.sol):
    // 1. Identify StakingRewards at 0xB3FB1D01B07A706736Ca175f827e4F56021b85dE; its stakingToken is the UniLP at 0xB1BbeEa2dA2905E6B0A30203aEf55c399C53D042.
    // 2. At attack block (14421983), query/observe that contract holds DRAIN_AMOUNT (~8.79e21 wei = 8792.87 LP) of stakingToken.
    // 3. Attacker EOA/contract (never staked, _balances[attacker]==0, _totalSupply reflects only legit stakes) calls withdraw(DRAIN_AMOUNT).
    // 4. _withdraw executes: require !=0 passes; updateReward(0) yields reward=0; underflow wraps _totalSupply and _balances[attacker]; transfer(DRAIN_AMOUNT) succeeds and moves real UniLP to attacker.
    // 5. Attacker receives the LP (value extracted); can exit Uniswap position. Contract left with drained balance and bogus accounting state.
    // 6. (Optional in PoC) No further interaction needed; single tx suffices. Total ~700k USD drained.
    // 
    // Why the PoC amount works: it is <= actual held tokens (so transfer doesn't revert) but >0 (bypasses only guard). Underflow always occurs for any amount when userStake==0.
    // 
    // Impact: Theft of all user-staked LP tokens with zero attacker capital at risk. Violates core staking invariant (you can only withdraw what you deposited).
    function _withdraw(uint256 amount, address user, address recipient) internal nonReentrant updateReward(user) {
        require(amount != 0, "Cannot withdraw 0");

        // not using safe math, because there is no way to overflow if stake tokens not overflow
        _totalSupply = _totalSupply - amount;
        _balances[user] = _balances[user] - amount;
        // not using safe transfer, because we working with trusted tokens
        require(stakingToken.transfer(recipient, amount), "token transfer failed");

        emit Withdrawn(user, amount);
    }

    /// @param user address
    /// @param recipient address, where to send reward
    function _getReward(address user, address recipient)
        internal
        virtual
        nonReentrant
        updateReward(user)
        returns (uint256 reward)
    {
        reward = rewards[user];

        if (reward != 0) {
            rewards[user] = 0;
            OnDemandToken(address(rewardsToken)).mint(recipient, reward);
            emit RewardPaid(user, reward);
        }
    }
}
