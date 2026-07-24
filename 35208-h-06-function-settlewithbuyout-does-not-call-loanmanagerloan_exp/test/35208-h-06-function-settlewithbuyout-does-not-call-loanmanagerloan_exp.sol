// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35208-h-06-function-settlewithbuyout-does-not-call-loanmanagerloan.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-06] — settleWithBuyout skips Pool.loanLiquidation.

    Re-asserts: outstanding uncleared, repaid principal locked off cashAccounting.
//////////////////////////////////////////////////////////////////////////*/
contract SettleBuyoutMissingLiquidationTest is Test {
    function test_settleWithBuyout_skips_loanLiquidation_locks_principal() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.outstandingAfter(), exp.POOL_PRINCIPAL(), "outstanding uncleared");
        assertEq(exp.locked(), exp.POOL_PRINCIPAL(), "locked unaccounted");
        assertEq(exp.usdc().balanceOf(address(exp.pool())), exp.POOL_PRINCIPAL(), "tokens stuck");
    }
}
