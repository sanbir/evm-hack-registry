// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, OperationalTreasury, MiniStable, MarkerToken} from
    "./57739-h-02-insufficient-liquidity-checks-for-put-may-cause-exercis.sol";

// Hyperhyper H-02 (finding 57739): `_checkEnoughLiquidity` gates a PUT open on
// the TOTAL stablecoin value of the pool, not on the balance of the payout token
// `pos.buyToken`. A USDC PUT opens while poolAmount[USDC]==0 (pool holds 3500
// USDXL, 0 USDC), then a profitable exercise reverts in `_payout` on
// `poolAmount[USDC] -= pnl`, permanently stranding the holder's $500 payout.
contract Finding57739Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_putUnexercisable_strandsPayout() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("denied payout (owed pnl)", e.deniedPayout());
        emit log_named_uint("stuck payout minted to SINK", e.stuckPayout());

        // the flawed check let a USDC PUT open against a pool holding 0 USDC
        assertTrue(e.openedDespiteNoUSDC(), "PUT should have opened despite 0 USDC");
        // the profitable exercise reverts (poolAmount[USDC] -= pnl underflows)
        assertTrue(e.exerciseReverted(), "exercise should revert, stranding the payout");
        // the stranded payout magnitude is recorded at SINK
        assertEq(e.deniedPayout(), 500 ether, "holder owed 500 USDC");
        assertEq(e.marker().balanceOf(SINK), 500 ether, "500e18 stuck-payout marker at SINK");
    }
}
