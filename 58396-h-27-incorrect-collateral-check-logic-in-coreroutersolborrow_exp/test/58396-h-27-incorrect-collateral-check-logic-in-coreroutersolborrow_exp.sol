// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CoreRouterFixed} from "./58396-h-27-incorrect-collateral-check-logic-in-coreroutersolborrow.sol";

contract Finding58396Test is Test {
    function test_exploit_first_borrow_bypasses_collateral_check() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.borrowedReceived(), 1000 ether, "borrowed");
        assertEq(e.collateralPosted(), 100 ether, "collateral");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker tokens");
        assertEq(e.vuln().lastBorrowAmount(), 0, "zeroed check");
        assertEq(e.token().balanceOf(address(e.lToken())), 1000 ether, "reserve left");
    }

    function test_control_compare_hypothetical_debt_reverts() public {
        Exploit e = new Exploit();
        CoreRouterFixed fixedRouter = new CoreRouterFixed(address(e.lendStorage()));
        e.lendStorage().addCollateral(address(this), 100 ether);

        (bool ok, bytes memory data) = address(fixedRouter).call(
            abi.encodeWithSelector(fixedRouter.borrow.selector, uint256(1000 ether), address(e.token()))
        );
        assertFalse(ok, "fixed borrow should revert");
        assertEq(bytes4(data), bytes4(keccak256("Error(string)")), "reason");

        assertEq(e.token().balanceOf(address(this)), 0, "control received nothing");
        assertEq(e.token().balanceOf(address(e.lToken())), 2000 ether, "reserve intact");
    }
}
