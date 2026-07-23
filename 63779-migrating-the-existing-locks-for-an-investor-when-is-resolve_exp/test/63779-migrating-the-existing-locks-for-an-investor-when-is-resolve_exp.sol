// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63779-migrating-the-existing-locks-for-an-investor-when-is-resolve.sol";

contract LockMigrationGriefTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.locks().availableTokens(e.NEW_USER()), 0, "matured locks blocked by grief");
        assertEq(e.locks().lockCount(e.NEW_USER()), 5, "1 grief + 4 migrated");
    }

    function test_withoutGrief_maturedLockIsAvailableAfterResolve() public {
        LockUpManager locks = new LockUpManager(365 days);
        address oldUser = address(0x01d);
        address newUser = address(0x02e);
        uint32 nowT = uint32(2_000_000_000);
        uint32 LOCK_TIME = 365 days;

        locks.setTimeNow(nowT);
        locks.mintLocked(oldUser, 1, nowT - LOCK_TIME); // matured
        locks.mintLocked(oldUser, 1, nowT - LOCK_TIME / 2); // not matured

        assertEq(locks.availableTokens(oldUser), 1, "one matured before resolve");
        locks.resolveUser(oldUser, newUser);
        // No front grief lock → matured entry is first → available
        assertEq(locks.availableTokens(newUser), 1, "matured lock available after clean resolve");
    }
}
