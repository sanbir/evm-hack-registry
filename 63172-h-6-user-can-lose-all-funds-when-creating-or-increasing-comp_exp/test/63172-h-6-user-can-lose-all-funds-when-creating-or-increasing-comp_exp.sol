// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63172-h-6-user-can-lose-all-funds-when-creating-or-increasing-comp.sol";

contract AmmplifyFirstDepositTest is Test {
    function test_exploit_victimGetsZeroSharesAttackerSteals() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.victimShares(), 0, "0 shares");
        assertEq(e.victimLoss(), 300e18, "full deposit lost");
        assertGt(e.attackerRedeem(), 300e18, "attacker stole deposit");
    }
}
