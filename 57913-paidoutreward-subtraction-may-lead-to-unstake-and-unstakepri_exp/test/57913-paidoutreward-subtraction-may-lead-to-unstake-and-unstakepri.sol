// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAWhitelistedStaking — paidOutReward is not cleared when reward is
    (MixBytes, Lumina Staking, 2025-06, Critical 1).
    SYNTHETIC, cheatcode-free. The subtraction and the day formula are verbatim.

    A 10-day stake of 10,000 is claimed once. unstake zeros reward and leaves
    paidOutReward at 1,000. The next unstakePrincipal computes
    rewardToSend = reward - paidOutReward, which is 0 - 1,000, and reverts.
    10,000 principal stays in the contract. The 10 days are stored timestamps.
    run() does not warp. */

contract StakeToken {
    string public constant name = "WDIA";
    string public constant symbol = "WDIA";
    uint8 public constant decimals = 18;
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

    function openStake(uint256 amount) external returns (uint256 index) {
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
        return (rewardRatePerDay * passedDays * currentStore.principal) / 10000;
    }

    function updateReward(uint256 stakingStoreIndex) public {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 reward = getRewardForStakingStore(stakingStoreIndex);
        assert(reward >= currentStore.reward);
        currentStore.reward = reward;
    }

    function unstake(uint256 stakingStoreIndex) external {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        updateReward(stakingStoreIndex);
        uint256 rewardToSend = currentStore.reward - currentStore.paidOutReward;
        currentStore.paidOutReward += rewardToSend;
        currentStore.reward = 0;
        currentStore.stakingStartTime = uint64(block.timestamp);
        currentStore.unstakingRequestTime = 0;
        if (rewardToSend > 0) STAKING_TOKEN.transfer(msg.sender, rewardToSend);
    }

    function requestUnstake(uint256 stakingStoreIndex) external {
        stakingStores[stakingStoreIndex].unstakingRequestTime = uint64(block.timestamp);
    }

    function unstakePrincipal(uint256 stakingStoreIndex) external virtual {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        updateReward(stakingStoreIndex);
        // @> VULN: rewardToSend = currentStore.reward - currentStore.paidOutReward underflows
        uint256 rewardToSend = currentStore.reward - currentStore.paidOutReward;
        currentStore.paidOutReward += rewardToSend;
        uint256 principalToSend = currentStore.principal;
        currentStore.principal = 0;
        STAKING_TOKEN.transfer(msg.sender, principalToSend + rewardToSend);
    }

    function paidOutOf(uint256 index) external view returns (uint256) {
        return stakingStores[index].paidOutReward;
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

    function unstakePrincipal(uint256 stakingStoreIndex) external override {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 reward = getRewardForStakingStore(stakingStoreIndex);
        uint256 rewardToSend = reward > currentStore.paidOutReward ? reward - currentStore.paidOutReward : 0;
        currentStore.paidOutReward = reward;
        currentStore.reward = reward;
        uint256 principalToSend = currentStore.principal;
        currentStore.principal = 0;
        currentStore.unstakingRequestTime = 0;
        STAKING_TOKEN.transfer(msg.sender, principalToSend + rewardToSend);
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant RATE = 100;
    uint256 public constant FIRST_REWARD = 1_000 ether;

    StakeToken public token; // nonce 1
    DIAWhitelistedStaking public staking; // nonce 2

    uint256 public index;
    uint256 public paidOut;
    uint256 public storedReward;
    bool public secondReverted;
    uint256 public locked;
    uint256 public userGot;

    constructor() {
        token = new StakeToken();
        staking = new DIAWhitelistedStaking(token, RATE);
    }

    function run() external {
        token.mint(address(this), PRINCIPAL + FIRST_REWARD);
        token.transfer(address(staking), PRINCIPAL + FIRST_REWARD);
        index = staking.openStake(PRINCIPAL);
        staking.unstake(index);
        paidOut = staking.paidOutOf(index);
        storedReward = staking.rewardOf(index);
        staking.requestUnstake(index);
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.unstakePrincipal.selector, index));
        secondReverted = !ok;
        locked = token.balanceOf(address(staking));
        userGot = token.balanceOf(address(this));
        require(paidOut == FIRST_REWARD, "paidOut stays 1000");
        require(storedReward == 0, "reward was zeroed");
        require(secondReverted, "unstakePrincipal reverts");
        require(staking.principalOf(index) == PRINCIPAL, "principal still booked");
        require(locked == PRINCIPAL, "10000 WDIA locked");
        require(userGot == FIRST_REWARD, "only the first reward was paid");
    }
}
