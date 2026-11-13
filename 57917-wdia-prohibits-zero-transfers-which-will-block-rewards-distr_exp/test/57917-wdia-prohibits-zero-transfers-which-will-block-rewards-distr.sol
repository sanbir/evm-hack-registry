// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DIA WDIA — a zero transfer reverts, so a 100% principal share cannot unstake
    (MixBytes, Lumina Staking, 2025-06, Critical 5).
    SYNTHETIC, cheatcode-free. The token check and the unguarded transfer are verbatim.

    principalWalletShareBps is 10,000. Unstaking 1,100 (1,000 principal + 100
    reward) assigns the whole reward to the principal wallet and 0 to the
    beneficiary. WDIA reverts on that 0 transfer, so the 1,100 stays put.
    unstakingDuration is 0. run() does not warp. */

contract WDIA {
    string public constant name = "WDIA";
    string public constant symbol = "WDIA";
    uint8 public constant decimals = 18;
    error ZeroTransferAmount();
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        // @> VULN: if (wad == 0) revert ZeroTransferAmount()
        if (wad == 0) revert ZeroTransferAmount();
        if (src != msg.sender) {
            uint256 allowed = allowance[src][msg.sender];
            require(allowed >= wad, "allow");
            if (allowed != type(uint256).max) allowance[src][msg.sender] = allowed - wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        return true;
    }
}

contract DIAExternalStaking {
    struct ExternalStakingStore {
        address beneficiary;
        address principalPayoutWallet;
        uint256 principal;
        uint256 poolShares;
        uint32 principalWalletShareBps;
        uint64 unstakingRequestTime;
        uint256 requestedUnstakePrincipalAmount;
        uint256 requestedUnstakePrincipalRewardAmount;
        uint256 requestedUnstakeRewardAmount;
    }

    WDIA public STAKING_TOKEN;
    uint256 public unstakingDuration;
    uint256 public totalPoolSize;
    uint256 public totalShareAmount;
    uint256 public stakingIndex;
    mapping(uint256 => ExternalStakingStore) public stakingStores;

    constructor(WDIA token_) {
        STAKING_TOKEN = token_;
    }

    function stake(uint256 amount, uint32 principalWalletShareBps) external returns (uint256) {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), amount);
        uint256 shares = totalShareAmount == 0 ? amount : (amount * totalShareAmount) / totalPoolSize;
        totalPoolSize += amount;
        totalShareAmount += shares;
        stakingIndex++;
        ExternalStakingStore storage store = stakingStores[stakingIndex];
        store.beneficiary = msg.sender;
        store.principalPayoutWallet = msg.sender;
        store.principal = amount;
        store.poolShares = shares;
        store.principalWalletShareBps = principalWalletShareBps;
        return stakingIndex;
    }

    function addRewardToPool(uint256 amount) public {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), amount);
        totalPoolSize += amount;
    }

    function requestUnstake(uint256 stakingStoreIndex, uint256 amount) external {
        ExternalStakingStore storage currentStore = stakingStores[stakingStoreIndex];
        require(currentStore.unstakingRequestTime == 0, "already");
        currentStore.unstakingRequestTime = uint64(block.timestamp);
        uint256 currentAmountOfPool = (currentStore.poolShares * totalPoolSize) / totalShareAmount;
        require(amount <= currentAmountOfPool, "too much");
        uint256 poolSharesUnstakeAmount = (currentStore.poolShares * amount) / currentAmountOfPool;
        uint256 principalUnstakeAmount = (currentStore.principal * amount) / currentAmountOfPool;
        uint256 rewardUnstakeAmount = amount - principalUnstakeAmount;
        currentStore.principal -= principalUnstakeAmount;
        currentStore.poolShares -= poolSharesUnstakeAmount;
        totalPoolSize -= amount;
        totalShareAmount -= poolSharesUnstakeAmount;
        uint256 principalWalletReward =
            (rewardUnstakeAmount * currentStore.principalWalletShareBps) / 10000;
        uint256 beneficiaryReward = rewardUnstakeAmount - principalWalletReward;
        if (principalWalletReward > 0) {
            currentStore.requestedUnstakePrincipalRewardAmount = principalWalletReward;
        }
        currentStore.requestedUnstakePrincipalAmount = principalUnstakeAmount;
        currentStore.requestedUnstakeRewardAmount = beneficiaryReward;
    }

    function unstake(uint256 stakingStoreIndex) external virtual {
        ExternalStakingStore storage currentStore = stakingStores[stakingStoreIndex];
        require(currentStore.unstakingRequestTime != 0, "no request");
        require(currentStore.unstakingRequestTime + unstakingDuration <= block.timestamp, "wait");
        currentStore.unstakingRequestTime = 0;
        if (currentStore.requestedUnstakePrincipalRewardAmount > 0) {
            STAKING_TOKEN.transfer(
                currentStore.principalPayoutWallet, currentStore.requestedUnstakePrincipalRewardAmount
            );
        }
        STAKING_TOKEN.transfer(currentStore.principalPayoutWallet, currentStore.requestedUnstakePrincipalAmount);
        STAKING_TOKEN.transfer(currentStore.beneficiary, currentStore.requestedUnstakeRewardAmount);
    }

    function rewardOwed(uint256 index) external view returns (uint256) {
        return stakingStores[index].requestedUnstakeRewardAmount;
    }
}

contract DIAExternalStakingFixed is DIAExternalStaking {
    constructor(WDIA token_) DIAExternalStaking(token_) {}

    function unstake(uint256 stakingStoreIndex) external override {
        ExternalStakingStore storage currentStore = stakingStores[stakingStoreIndex];
        require(currentStore.unstakingRequestTime != 0, "no request");
        currentStore.unstakingRequestTime = 0;
        uint256 reward = currentStore.requestedUnstakePrincipalRewardAmount;
        uint256 principal = currentStore.requestedUnstakePrincipalAmount;
        uint256 benef = currentStore.requestedUnstakeRewardAmount;
        if (reward > 0) STAKING_TOKEN.transfer(currentStore.principalPayoutWallet, reward);
        if (principal > 0) STAKING_TOKEN.transfer(currentStore.principalPayoutWallet, principal);
        if (benef > 0) STAKING_TOKEN.transfer(currentStore.beneficiary, benef);
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 1_000 ether;
    uint256 public constant REWARD = 100 ether;
    uint32 public constant FULL_SHARE = 10_000;

    WDIA public token; // nonce 1
    DIAExternalStaking public staking; // nonce 2

    uint256 public index;
    uint256 public beneficiaryCut;
    bool public unstakeReverted;
    uint256 public locked;

    constructor() {
        token = new WDIA();
        staking = new DIAExternalStaking(token);
        token.mint(address(this), PRINCIPAL + REWARD);
    }

    function run() external {
        token.approve(address(staking), type(uint256).max);
        index = staking.stake(PRINCIPAL, FULL_SHARE);
        staking.addRewardToPool(REWARD);
        staking.requestUnstake(index, PRINCIPAL + REWARD);
        beneficiaryCut = staking.rewardOwed(index);
        (bool ok,) = address(staking).call(abi.encodeWithSelector(staking.unstake.selector, index));
        unstakeReverted = !ok;
        locked = token.balanceOf(address(staking));
        require(beneficiaryCut == 0, "beneficiary cut is 0");
        require(unstakeReverted, "zero transfer reverts");
        require(locked == PRINCIPAL + REWARD, "1100 locked");
        require(token.balanceOf(address(this)) == 0, "user received nothing");
    }
}
