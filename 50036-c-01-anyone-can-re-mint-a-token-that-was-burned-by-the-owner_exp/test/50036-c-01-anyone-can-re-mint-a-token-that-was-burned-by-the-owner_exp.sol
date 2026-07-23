// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50036-c-01-anyone-can-re-mint-a-token-that-was-burned-by-the-owner.sol";

/* NFTMirror C-01 — re-mint after owner burn leaves token unlocked (Pashov 2024-12) */
contract PoC_50036 is Test {
    function test_burnAndRemint() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.shadow().ownerOf(e.TOKEN_ID()), address(e.attacker()));
        assertEq(e.shadow().tokenIsLocked(e.TOKEN_ID()), false);
    }

    function test_freshMintStillLockedForNonBeacon() public {
        Exploit e = new Exploit();
        // Fresh id defaults locked — non-beacon mint must revert
        NFTShadow shadow = e.shadow();
        vm.expectRevert(bytes("CallerNotBeacon"));
        shadow.mint(address(this), 999);
    }
}
