// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./43546-h-01-function-poolmanagersync-called-before-the-unlock-proce.sol";

contract Finding43546Test is Test {
    function test_sync_before_unlock_reverts_and_sticks_output() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.rebalanceReverted(), "reverted");
        assertFalse(e.hook().rebalanced(), "flag");
        assertEq(e.poolManager().syncedCurrency(), address(0), "not synced");
        assertEq(e.token().balanceOf(address(e.hook())), 60 ether, "stuck");
        assertEq(e.token().balanceOf(address(e.poolManager())), 0, "pool");
    }
}
