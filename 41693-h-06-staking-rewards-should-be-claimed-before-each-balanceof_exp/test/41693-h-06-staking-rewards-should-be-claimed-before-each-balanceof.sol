// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DYAD — H-06 (Pashov, AuditVault 41693)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: UniswapV3Staking._calculateRewards multiplies the whole
    elapsed window by the live balanceOfNote. withdraw/burn/mint changes
    that balance without claiming first, so the note is paid at the new XP
    for time it held the old XP.
    Blamed lines copied verbatim (@> VULN).
    The note was staked at timestamp 0. This block's timestamp is 1, so
    timeDiff is 1 with no warp inside run(). */

contract RewardToken {
    string public name = "Kerosene";
    string public symbol = "KEROSENE";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DyadXP {
    mapping(uint256 => uint256) public noteXp;

    function balanceOfNote(uint256 noteId) external view returns (uint256) {
        return noteXp[noteId];
    }

    function setNote(uint256 noteId, uint256 xp) external {
        noteXp[noteId] = xp;
    }

    /// Balance-changing path. Does not claim staking rewards first.
    function withdrawKerosene(uint256 noteId) external {
        noteXp[noteId] = 0;
    }
}

contract RewardHolder {
    function approve(RewardToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract UniswapV3Staking {
    struct StakeInfo {
        uint128 liquidity;
        uint256 lastRewardTime;
        bool isStaked;
    }

    mapping(uint256 => StakeInfo) public stakes;
    uint256 public rewardsRate;
    DyadXP public dyadXP;
    RewardToken public rewardsToken;
    address public rewardsTokenHolder;

    constructor(DyadXP _xp, RewardToken _rewards, address _holder, uint256 _rate) {
        dyadXP = _xp;
        rewardsToken = _rewards;
        rewardsTokenHolder = _holder;
        rewardsRate = _rate;
    }

    function stake(uint256 noteId, uint128 liquidity, uint256 lastRewardTime) external {
        stakes[noteId] = StakeInfo({liquidity: liquidity, lastRewardTime: lastRewardTime, isStaked: true});
    }

    function _calculateRewards(uint256 noteId, StakeInfo storage stakeInfo) internal view returns (uint256) {
        uint256 timeDiff = block.timestamp - stakeInfo.lastRewardTime;

        // @> VULN: live balanceOfNote. A withdraw that skipped claimRewards prices the whole window at the new XP.
        uint256 xp = dyadXP.balanceOfNote(noteId);

        return timeDiff * rewardsRate * stakeInfo.liquidity * xp;
    }

    function claimRewards(uint256 noteId) external returns (uint256 rewards) {
        StakeInfo storage stakeInfo = stakes[noteId];
        require(stakeInfo.isStaked, "Note not staked");
        rewards = _calculateRewards(noteId, stakeInfo);
        stakeInfo.lastRewardTime = block.timestamp;
        if (rewards > 0) {
            rewardsToken.transferFrom(rewardsTokenHolder, msg.sender, rewards);
        }
    }
}

contract Exploit {
    uint256 public constant NOTE = 1;
    uint256 public constant XP = 1000e18;
    uint256 public constant REWARD = 1000e18;

    RewardToken public reward; // CREATE nonce 1
    DyadXP public dyadXP; // CREATE nonce 2
    RewardHolder public holder; // CREATE nonce 3
    UniswapV3Staking public staking; // CREATE nonce 4

    uint256 public paid;
    uint256 public fair;
    uint256 public userBalance;
    uint256 public holderBalance;

    constructor() {
        reward = new RewardToken();
        dyadXP = new DyadXP();
        holder = new RewardHolder();
        staking = new UniswapV3Staking(dyadXP, reward, address(holder), 1);
        dyadXP.setNote(NOTE, XP);
        staking.stake(NOTE, 1, 0);
        reward.mint(address(this), REWARD);
    }

    function run() external {
        uint256 xpBefore = dyadXP.balanceOfNote(NOTE);
        require(xpBefore == XP, "xp is 1000e18");
        (uint128 liquidity, uint256 lastRewardTime,) = staking.stakes(NOTE);

        reward.transfer(address(holder), REWARD);
        holder.approve(reward, address(staking), REWARD);

        dyadXP.withdrawKerosene(NOTE);
        require(dyadXP.balanceOfNote(NOTE) == 0, "xp is now 0");

        paid = staking.claimRewards(NOTE);
        require(paid == 0, "claim paid 0");

        fair = (block.timestamp - lastRewardTime) * staking.rewardsRate() * uint256(liquidity) * xpBefore;
        require(fair == REWARD, "fair reward was 1000e18");

        userBalance = reward.balanceOf(address(this));
        holderBalance = reward.balanceOf(address(holder));
        require(userBalance == 0, "user received 0");
        require(holderBalance == REWARD, "1000 still in the holder");
    }
}
