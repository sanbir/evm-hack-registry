// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    Servicer,
    TermRepoLockerFixed,
    Receiver
} from "./26296-borrowers-cannot-withdraw-excess-collateral-after-liquidatio.sol";

contract Finding26296Test is Test {
    function test_exploit_excess_stays_after_repayment() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.coll().balanceOf(address(e.locker())), 500 ether, "500 stuck");
        assertEq(e.coll().balanceOf(e.borrower()), 0, "borrower unpaid");
    }

    function test_control_pays_excess_when_obligation_is_zero() public {
        MockToken coll = new MockToken();
        Servicer servicer = new Servicer();
        Receiver borrower = new Receiver();
        TermRepoLockerFixed locker = new TermRepoLockerFixed(address(coll), address(servicer));
        servicer.setObligation(address(borrower), 0);
        coll.mint(address(locker), 500 ether);

        locker.externalUnlockCollateral(address(borrower), 500 ether);

        assertEq(coll.balanceOf(address(borrower)), 500 ether, "borrower received 500");
        assertEq(coll.balanceOf(address(locker)), 0, "locker empty");
    }
}
