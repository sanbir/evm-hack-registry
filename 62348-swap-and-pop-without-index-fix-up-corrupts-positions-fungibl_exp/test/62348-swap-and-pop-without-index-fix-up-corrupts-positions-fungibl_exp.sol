// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PositionManager,
    MockToken
} from "./62348-swap-and-pop-without-index-fix-up-corrupts-positions-fungibl.sol";

/// @dev Foundry driver for finding #62348. Re-asserts the Position array/mapping
///      desync harm after the vulnerable swap-and-pop path runs.
contract SwapAndPopIndexFixupTest is Test {
    function test_removeFungible_missingIndexFixup_corruptsArray() public {
        Exploit e = new Exploit();
        e.run();

        PositionManager pm = e.pm();
        uint256 id = e.positionId();
        MockToken tokenB = e.tokenB();

        // B has a ghost mapping balance of 1 ether
        assertEq(pm.fungibleBalance(id, address(tokenB)), 1 ether, "ghost B balance");
        // B is not present in the enumeration array
        uint256 len = pm.fungiblesLength(id);
        bool found;
        for (uint256 i = 0; i < len; ++i) {
            if (pm.fungibleAt(id, i) == address(tokenB)) found = true;
        }
        assertFalse(found, "B must be missing from fungibles[]");
        // Appraisal under-counts (true collateral 1e18, enumerated < 1e18)
        assertLt(pm.appraise(id), 1 ether, "appraisal under-counts");
        assertEq(e.ghostBalanceB(), 1 ether);
        assertFalse(e.bInArray());
    }

    /// @dev Control: removing the TAIL element does not move anything, so no
    ///      stale index is left behind — subsequent removals stay consistent.
    function test_removeTail_doesNotCorrupt() public {
        Exploit e = new Exploit();
        PositionManager pm = e.pm();
        MockToken tokenA = e.tokenA();
        MockToken tokenB = e.tokenB();
        MockToken tokenC = e.tokenC();

        uint256 id = pm.open();
        tokenA.mint(address(this), 1 ether);
        tokenB.mint(address(this), 1 ether);
        tokenC.mint(address(this), 1 ether);
        tokenA.approve(address(pm), 1 ether);
        tokenB.approve(address(pm), 1 ether);
        tokenC.approve(address(pm), 1 ether);
        // open() set owner to address(this) only if we call it — but Exploit owns
        // its own position. Use a fresh PositionManager via a local helper.
        // Simpler: use e's tokens but a new manager we own.
        PositionManager pm2 = new PositionManager();
        uint256 id2 = pm2.open();
        MockToken a = new MockToken("a");
        MockToken b = new MockToken("b");
        MockToken c = new MockToken("c");
        a.mint(address(this), 1 ether);
        b.mint(address(this), 1 ether);
        c.mint(address(this), 1 ether);
        a.approve(address(pm2), 1 ether);
        b.approve(address(pm2), 1 ether);
        c.approve(address(pm2), 1 ether);
        pm2.deposit(id2, address(a), 1 ether);
        pm2.deposit(id2, address(b), 1 ether);
        pm2.deposit(id2, address(c), 1 ether);

        // remove TAIL (C) — no swap, indexes of A/B stay correct
        pm2.withdraw(id2, address(c), 1 ether);
        assertEq(pm2.fungiblesLength(id2), 2);
        assertEq(pm2.fungibleIndex(id2, address(a)), 1);
        assertEq(pm2.fungibleIndex(id2, address(b)), 2);

        // remove A (non-tail) still leaves B's index stale — bug is real —
        // but removing only the tail path is the "safe" precondition control.
        assertEq(pm2.appraise(id2), 2 ether);
    }
}
