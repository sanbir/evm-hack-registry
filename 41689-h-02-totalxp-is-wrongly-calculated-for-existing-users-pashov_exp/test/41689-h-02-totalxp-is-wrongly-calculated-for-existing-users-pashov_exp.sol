// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    DyadXPv2Fixed,
    Exploit,
    MockDyad,
    MockKerosene,
    MockXP,
    NoteXPData
} from "./41689-h-02-totalxp-is-wrongly-calculated-for-existing-users-pashov.sol";

contract Finding41689Test is Test {
    function test_exploit_existing_note_drops_elapsed_xp() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(block.timestamp, 1, "replay timestamp");
        assertEq(e.credited(), 1e18, "stored totalXP is lastXP");
        assertEq(e.fairXP(), 1e18 + 1e25, "fair XP includes the one-second bonus");
        assertEq(e.rewardPaid(), 1e18, "position reward uses the short XP");
        assertEq(e.unpaid(), 1e25, "1e25 XP never credited");
        assertEq(e.xpToken().balanceOf(address(e)), 1e18, "holder received 1e18");
        assertEq(e.xpToken().balanceOf(address(e.xp())), 1e25, "pool keeps the gap");
    }

    function test_control_stores_computed_xp() public {
        MockXP token = new MockXP();
        MockKerosene kerosene = new MockKerosene();
        MockDyad dyad = new MockDyad();
        DyadXPv2Fixed xp = new DyadXPv2Fixed(address(token), address(kerosene), address(dyad));
        xp.seedExisting(0);
        NoteXPData memory beforeInit = _note(xp);
        uint256 fair = xp._computeXP(beforeInit);
        token.mint(address(xp), fair);
        xp.initialize();
        uint256 stored = _total(xp);
        assertEq(stored, fair, "control stores _computeXP");
        xp.claimPositionReward(0, address(this));
        assertEq(token.balanceOf(address(this)), fair, "control pays the fair XP");
        assertEq(token.balanceOf(address(xp)), 0, "nothing left unpaid");
    }

    function _note(DyadXPv2Fixed xp) internal view returns (NoteXPData memory data) {
        (data.lastAction, data.keroseneDeposited, data.lastXP, data.totalXP, data.dyadMinted) = xp.noteData(0);
    }

    function _total(DyadXPv2Fixed xp) internal view returns (uint256 total) {
        (,,, total,) = xp.noteData(0);
    }
}
