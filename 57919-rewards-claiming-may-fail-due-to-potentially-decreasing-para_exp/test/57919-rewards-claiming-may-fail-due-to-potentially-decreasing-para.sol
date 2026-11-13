// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAWhitelistedStaking — updateReward asserts the reward never falls
    (MixBytes, Lumina Staking, 2025-06).
    SYNTHETIC, cheatcode-free. getRewardForStakingStore and the assert are verbatim.

    A 10-day-old stake of 10_000 is partially unstaked for 5_000. unstakePrincipal
    pays that half and does not clear currentStore.reward. The next unstake calls
    updateReward, the new principal makes the formula smaller than the stored
    reward, and the assert reverts. The remaining 5_000 principal stays locked.
    No vm.warp: the stake's start is stored 10 days before this block. */

contract StakeToken {
    string public name = "WDIA";
    string public symbol = "WDIA";
    uint8 public decimals = 18;
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

contract DIAWhitelistedStaking {
    struct StakingStore {
        uint256 principal;
        uint256 reward;
        uint256 paidOutReward;
        uint64 stakingStartTime;
        uint64 unstakingRequestTime;
    }

    uint256 public rewardRatePerDay;
    StakeToken public STAKING_TOKEN;
    StakingStore[] public stakingStores;

    constructor(StakeToken token_, uint256 rate_) {
        STAKING_TOKEN = token_;
        rewardRatePerDay = rate_;
    }

    function stake(uint256 amount) external returns (uint256 index) {
        // Principal is already on this contract. A stake opened at t = 1 with an
        // unstake requested 10 days later. The formula reads those stored timestamps.
        stakingStores.push(
            StakingStore({
                principal: amount,
                reward: 0,
                paidOutReward: 0,
                stakingStartTime: 1,
                unstakingRequestTime: uint64(1 + 10 days)
            })
        );
        return stakingStores.length - 1;
    }

    function getRewardForStakingStore(uint256 stakingStoreIndex) public view returns (uint256) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 passedSeconds;
        if (currentStore.unstakingRequestTime > 0) {
            passedSeconds = currentStore.unstakingRequestTime - currentStore.stakingStartTime;
        } else {
            passedSeconds = block.timestamp - currentStore.stakingStartTime;
        }
        uint256 passedDays = passedSeconds / (24 * 60 * 60);
        // @audit assumption: reward rate is measured in bps — audited formula
        return (rewardRatePerDay * passedDays * currentStore.principal) / 10000;
    }

    function updateReward(uint256 stakingStoreIndex) public {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 reward = getRewardForStakingStore(stakingStoreIndex);
        // @> VULN: a smaller principal makes this reward fall below currentStore.reward
        assert(reward >= currentStore.reward);
        currentStore.reward = reward;
    }

    /// Partial principal unstake. Pays `amount` and the stored reward, then leaves `reward` in place.
    function unstakePrincipal(uint256 stakingStoreIndex, uint256 amount) external virtual {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        updateReward(stakingStoreIndex);
        currentStore.principal = currentStore.principal - amount;
        uint256 rewardToSend = currentStore.reward - currentStore.paidOutReward;
        currentStore.paidOutReward += rewardToSend;
        currentStore.stakingStartTime = uint64(block.timestamp);
        currentStore.unstakingRequestTime = 0;
        STAKING_TOKEN.transfer(msg.sender, amount + rewardToSend);
    }

    function principalOf(uint256 index) external view returns (uint256) {
        return stakingStores[index].principal;
    }

    function rewardOf(uint256 index) external view returns (uint256) {
        return stakingStores[index].reward;
    }
}

contract DIAWhitelistedStakingFixed is DIAWhitelistedStaking {
    constructor(StakeToken token_, uint256 rate_) DIAWhitelistedStaking(token_, rate_) {}

    function unstakePrincipal(uint256 stakingStoreIndex, uint256 amount) external override {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 reward = getRewardForStakingStore(stakingStoreIndex);
        if (reward > currentStore.paidOutReward) {
            uint256 rewardToSend = reward - currentStore.paidOutReward;
            currentStore.paidOutReward += rewardToSend;
            STAKING_TOKEN.transfer(msg.sender, rewardToSend);
        }
        currentStore.reward = reward;
        currentStore.principal = currentStore.principal - amount;
        currentStore.stakingStartTime = uint64(block.timestamp);
        currentStore.unstakingRequestTime = 0;
        STAKING_TOKEN.transfer(msg.sender, amount);
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant HALF = 5_000 ether;
    uint256 public constant RATE = 100;
    uint256 public constant FIRST_REWARD = 1_000 ether;

    StakeToken public token; // nonce 1
    DIAWhitelistedStaking public staking; // nonce 2

    uint256 public index;
    uint256 public leftPrincipal;
    uint256 public storedReward;
    bool public secondReverted;
    uint256 public userGot;

    constructor() {
        token = new StakeToken();
        staking = new DIAWhitelistedStaking(token, RATE);
    }

    function run() external {
        token.mint(address(this), PRINCIPAL + FIRST_REWARD);
        token.transfer(address(staking), PRINCIPAL + FIRST_REWARD);
        index = staking.stake(PRINCIPAL);
        staking.unstakePrincipal(index, HALF);
        leftPrincipal = staking.principalOf(index);
        storedReward = staking.rewardOf(index);
        (bool ok,) = address(staking).call(
            abi.encodeWithSelector(staking.unstakePrincipal.selector, index, HALF)
        );
        secondReverted = !ok;
        userGot = token.balanceOf(address(this));
        require(leftPrincipal == HALF, "5000 still staked");
        require(storedReward == FIRST_REWARD, "reward not cleared");
        require(secondReverted, "second unstake reverts");
        require(staking.principalOf(index) == HALF, "still locked");
        require(token.balanceOf(address(staking)) == HALF, "5000 tokens locked");
    }
}
