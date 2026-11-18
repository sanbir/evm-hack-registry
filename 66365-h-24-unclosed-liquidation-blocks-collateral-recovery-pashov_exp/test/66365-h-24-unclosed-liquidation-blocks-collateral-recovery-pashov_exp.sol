// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./66365-h-24-unclosed-liquidation-blocks-collateral-recovery-pashov.sol";

contract Finding66365Test is Test {
    function test_zero_debt_still_cannot_close_or_withdraw() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.closeReverted(), "close");
        assertTrue(e.withdrawReverted(), "withdraw");
        assertTrue(e.pool().underLiquidation(address(e.user())), "flag");
        assertEq(e.pool().debtOf(address(e.user())), 0, "debt");
        assertEq(e.collateral().balanceOf(address(e.pool())), 80 ether, "locked");
        assertEq(e.collateral().balanceOf(address(e.user())), 0, "user");
    }
}
