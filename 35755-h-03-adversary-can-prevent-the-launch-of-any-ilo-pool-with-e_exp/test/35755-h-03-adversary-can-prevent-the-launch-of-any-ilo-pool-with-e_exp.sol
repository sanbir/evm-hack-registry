// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35755-h-03-adversary-can-prevent-the-launch-of-any-ilo-pool-with-e.sol";

contract VultisigLaunchDosExpTest is Test {
    function test_launch_permanently_blocked_by_single_sided_liquidity() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.mitigationWorkedBeforeAttack(), "pre-attack mitigation should have worked");
        assertTrue(e.mitigationFailedAfterAttack(), "post-attack mitigation must fail");
        assertTrue(e.launchPermanentlyBlocked(), "launch must be permanently blocked");
    }

    /// @dev Control: without ever minting single-sided liquidity, the price
    ///      can always be swapped back and launch() succeeds normally.
    function test_control_no_attack_launch_succeeds() public {
        MockUniV3Pool pool = new MockUniV3Pool(79228162514264337593543950336);
        ILOManager manager = new ILOManager();
        manager.initProject(address(pool), 79228162514264337593543950336, 0);

        // Someone swaps the price around, then swaps it back -- no single-sided
        // liquidity was ever minted, so nothing blocks the mitigation.
        pool.swap(address(this), true, 1, 4295128740, "");
        pool.swap(address(this), false, 1, 79228162514264337593543950336, "");

        manager.launch(address(pool)); // must NOT revert
    }
}
