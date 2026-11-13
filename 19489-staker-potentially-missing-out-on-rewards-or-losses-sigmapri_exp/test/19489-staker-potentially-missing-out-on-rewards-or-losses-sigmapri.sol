// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Linkpool StakingPool — withdraw prices shares off totalStaked and ignores
    rewards that updateStrategyRewards has not folded in (Sigma Prime, 19489).

    SYNTHETIC, cheatcode-free. The staker holds 10 percent. The strategy has
    earned 100e18 that is still pending. Fair value is 110e18. withdraw pays
    100e18. The missing reward is 10e18.

    The control folds the reward in before the transfer and pays 110e18. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingPool {
    Asset public asset;
    uint256 public totalShares;
    uint256 public totalStaked;
    uint256 public pendingReward;
    mapping(address => uint256) public sharesOf;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function stake(address who, uint256 amount) external {
        uint256 shares = totalShares == 0 ? amount : amount * totalShares / totalStaked;
        asset.transferFrom(msg.sender, address(this), amount);
        sharesOf[who] += shares;
        totalShares += shares;
        totalStaked += amount;
    }

    function earn(uint256 reward) external {
        asset.transferFrom(msg.sender, address(this), reward);
        pendingReward += reward;
    }

    function updateStrategyRewards() public {
        totalStaked += pendingReward;
        pendingReward = 0;
    }

    function fairAssets(address who) public view returns (uint256) {
        return sharesOf[who] * (totalStaked + pendingReward) / totalShares;
    }

    function withdraw(address who) external virtual {
        uint256 assets = sharesOf[who] * totalStaked / totalShares;
        sharesOf[who] = 0;
        _pay(who, assets);
    }

    function _pay(address who, uint256 assets) internal virtual {
        // @> VULN: the payout uses totalStaked and skips pendingReward, so the staker misses the strategy gain.
        asset.transfer(who, assets);
        // FIX: call updateStrategyRewards before pricing the withdrawal.
    }
}

contract StakingPoolFixed is StakingPool {
    constructor(Asset _asset) StakingPool(_asset) {}

    function withdraw(address who) external override {
        updateStrategyRewards();
        uint256 assets = sharesOf[who] * totalStaked / totalShares;
        sharesOf[who] = 0;
        asset.transfer(who, assets);
    }
}

contract Exploit {
    uint256 public constant STAKE = 100 ether;
    uint256 public constant OTHERS = 900 ether;
    uint256 public constant REWARD = 100 ether;
    uint256 public constant FAIR = 110 ether;
    uint256 public constant N = 10 ether;

    Asset public asset;
    StakingPool public pool;
    uint256 public paid;
    uint256 public fair;

    constructor() {
        asset = new Asset();
        pool = new StakingPool(asset);
    }

    function run() external {
        asset.mint(address(this), STAKE + OTHERS + REWARD);
        pool.stake(address(0xBEEF), OTHERS);
        pool.stake(address(this), STAKE);
        pool.earn(REWARD);
        fair = pool.fairAssets(address(this));
        uint256 beforeBal = asset.balanceOf(address(this));
        pool.withdraw(address(this));
        paid = asset.balanceOf(address(this)) - beforeBal;
        require(fair == FAIR, "fair is not 110e18");
        require(paid == STAKE, "paid is not 100e18");
        require(fair - paid == N, "harm");
    }
}
