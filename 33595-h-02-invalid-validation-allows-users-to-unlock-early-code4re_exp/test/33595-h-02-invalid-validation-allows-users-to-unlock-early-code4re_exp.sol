// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./33595-h-02-invalid-validation-allows-users-to-unlock-early-code4re.sol";

/*//////////////////////////////////////////////////////////////////////////
    Munchables [H-02] — invalid validation allows users to unlock early.

    Driver test for the cheatcode-free synthetic. Deploys the Exploit (which
    wires the reduced LockManager in its constructor), runs the attack
    sequence, and independently re-asserts the harm:
      * Alice's balance is fully unlocked while her ORIGINAL unlock time has
        not yet arrived,
      * a control scenario with zero elapsed time since the lock shows the
        identical first reduction attempt is correctly blocked.
//////////////////////////////////////////////////////////////////////////*/
contract UnlockEarlyTest is Test {
    function test_setLockDuration_letsAliceUnlockEarly() public {
        // Realistic block timestamp (the Playground replays this at a real
        // unix timestamp from anvil_state.json; forge's default test
        // timestamp starts near 1, which would underflow the PoC-only
        // backdate arithmetic).
        vm.warp(1_700_000_000);

        Exploit exp = new Exploit();
        LockManager lm = exp.lm();

        // === attack: backdated lock -> two setLockDuration calls -> unlock ===
        exp.run();

        // HARM #1 — Alice's balance is fully withdrawn.
        assertEq(lm.quantityOf(address(exp)), 0, "alice's full balance was unlocked");

        // HARM #2 — this happened while the pool still thinks "now" is far
        // before her ORIGINAL commitment would have allowed.
        // (unlockTimeOf was already collapsed inside run(); re-derive the
        // original promise independently from the exploit's own constants.)
        uint32 originalUnlockTime = uint32(block.timestamp) - exp.BACKDATE() + exp.ORIGINAL_DURATION();
        assertLt(block.timestamp, originalUnlockTime, "unlocked strictly before the ORIGINAL commitment date");
    }

    /// @notice Control: with zero elapsed time between lock and the first
    ///         reduction attempt (a genuine same-block lock+reduce), the
    ///         identical reduction call is correctly BLOCKED -- confirming
    ///         the bug specifically requires real elapsed time since the
    ///         original lock, matching the report's own explanation.
    function test_control_noElapsedTime_reductionIsBlocked() public {
        vm.warp(1_700_000_000);
        LockManager lm = new LockManager();
        lm.lock(100 ether, 100_000, 0); // no backdate: lastLockTime == block.timestamp

        vm.expectRevert();
        lm.setLockDuration(50_001);
    }
}
