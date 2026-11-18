// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, Pocket, VaultFixed, Borrower} from
    "./40212-liquidated-person-s-debts-are-not-reduced-in-liquidation-can.sol";

contract Finding40212Test is Test {
    function test_exploit_second_liquidation_seizes_another_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.seized(), 2000 ether, "liquidator took 2000");
        assertEq(e.debtLeft(), 1000 ether, "debt unchanged");
        assertEq(e.vault().collateralOf(address(e.borrower())), 0, "no collateral left");
        assertEq(e.collateral().balanceOf(address(e)), 2000 ether, "exploit holds 2000");
    }

    function test_control_clearing_debt_stops_the_second_seizure() public {
        Token collateral = new Token("COLL");
        Token tcap = new Token("TCAP");
        Pocket pocket = new Pocket(collateral);
        VaultFixed fixedVault = new VaultFixed(collateral, tcap, pocket);
        Borrower borrower = new Borrower();
        collateral.mint(address(borrower), 2000 ether);
        tcap.mint(address(this), 1000 ether);

        borrower.openFixed(fixedVault, collateral, 1000 ether);
        fixedVault.liquidate(address(borrower), 1, 1000 ether);
        borrower.depositMoreFixed(fixedVault, collateral, 1000 ether);
        vm.expectRevert(bytes("healthy"));
        fixedVault.liquidate(address(borrower), 1, 1 ether);

        assertEq(collateral.balanceOf(address(this)), 1000 ether, "only the first seizure");
        assertEq(fixedVault.debtOf(address(borrower)), 0, "debt cleared");
        assertEq(fixedVault.collateralOf(address(borrower)), 1000 ether, "second deposit kept");
    }
}
