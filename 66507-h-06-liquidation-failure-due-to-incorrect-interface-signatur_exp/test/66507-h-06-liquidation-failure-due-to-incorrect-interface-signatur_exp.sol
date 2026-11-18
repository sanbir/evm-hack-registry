// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit, LiquidationSwapFixed, ITwocryptoNg} from "./66507-h-06-liquidation-failure-due-to-incorrect-interface-signatur.sol";
contract Finding66507Test is Test {
    function test_exploit_liquidation_reverts_and_debt_remains() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.reverted(), "reverted");
        assertEq(e.swap().debt(e.borrower()), 1000 ether, "debt");
        assertEq(e.stability().seized(), 0, "seized");
        assertEq(e.collateral().balanceOf(address(e.swap())), 100 ether, "collateral stuck with the position");
    }
    function test_control_uint256_interface_liquidates() public {
        Exploit e = new Exploit();
        LiquidationSwapFixed fixedS = new LiquidationSwapFixed(ITwocryptoNg(address(e.pool())), e.collateral(), e.stability());
        e.collateral().mint(address(fixedS), 100 ether);
        fixedS.setDebt(e.borrower(), 1000 ether);
        fixedS.liquidateBorrower(e.borrower(), 1000 ether);
        assertEq(fixedS.debt(e.borrower()), 0, "debt cleared");
        assertEq(e.stability().seized(), 100 ether, "collateral seized");
    }
}
