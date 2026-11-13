// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAWhitelistedStaking — passedDays floors away a partial day
    (MixBytes, Lumina Staking, 2025-06, High 1).
    SYNTHETIC, cheatcode-free. The division is verbatim.

    A 10,000 stake whose stored window is 12 hours has passedDays = 0, so the
    formula pays 0 instead of 50 WDIA. Those 50 are moved into the contract
    as the reward for that window and stay there. The 12 hours are two stored
    timestamps. run() does not warp. */

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
                stakingStartTime: 1,
                unstakingRequestTime: uint64(1 + 12 hours)
            })
        );
        return stakingStores.length - 1;
    }

    function getRewardForStakingStore(uint256 stakingStoreIndex) public view virtual returns (uint256) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 passedSeconds = currentStore.unstakingRequestTime - currentStore.stakingStartTime;
        // @> VULN: passedDays = passedSeconds / (24 * 60 * 60) drops a partial day
        uint256 passedDays = passedSeconds / (24 * 60 * 60);
        return (rewardRatePerDay * passedDays * currentStore.principal) / 10000;
    }

    function unstake(uint256 stakingStoreIndex) external returns (uint256 rewardToSend) {
        rewardToSend = getRewardForStakingStore(stakingStoreIndex);
        if (rewardToSend > 0) STAKING_TOKEN.transfer(msg.sender, rewardToSend);
    }
}

contract DIAWhitelistedStakingFixed is DIAWhitelistedStaking {
    constructor(StakeToken token_, uint256 rate_) DIAWhitelistedStaking(token_, rate_) {}

    function getRewardForStakingStore(uint256 stakingStoreIndex) public view override returns (uint256) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 passedSeconds = currentStore.unstakingRequestTime - currentStore.stakingStartTime;
        return (rewardRatePerDay * passedSeconds * currentStore.principal) / (1 days * 10000);
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant RATE = 100;
    uint256 public constant FAIR = 50 ether;

    StakeToken public token; // nonce 1
    DIAWhitelistedStaking public staking; // nonce 2

    uint256 public index;
    uint256 public quoted;
    uint256 public paid;
    uint256 public kept;

    constructor() {
        token = new StakeToken();
        staking = new DIAWhitelistedStaking(token, RATE);
        token.mint(address(this), FAIR);
    }

    function run() external {
        index = staking.openStake(PRINCIPAL);
        quoted = staking.getRewardForStakingStore(index);
        token.transfer(address(staking), FAIR);
        paid = staking.unstake(index);
        kept = token.balanceOf(address(staking));
        require(quoted == 0, "12 hours quotes 0");
        require(paid == 0, "nothing paid");
        require(kept == FAIR, "50 WDIA stays");
        require(token.balanceOf(address(this)) == 0, "user got nothing");
    }
}
