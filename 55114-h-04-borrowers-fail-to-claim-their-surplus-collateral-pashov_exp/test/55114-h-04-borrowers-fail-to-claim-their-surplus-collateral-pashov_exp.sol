// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Borrower,
    Collateral,
    Exploit,
    Staker,
    TroveManager
} from "./55114-h-04-borrowers-fail-to-claim-their-surplus-collateral-pashov.sol";

contract Finding55114Test is Test {
    function test_exploit_surplus_claim_reverts_and_6_stays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 6 ether, "6 stuck in the staker");
        assertEq(e.paid(), 0, "borrower received nothing");
        assertFalse(e.claimed(), "claim reverted");
    }

    function test_control_release_from_staker_pays_6() public {
        Collateral token = new Collateral();
        Staker staker = new Staker(token);
        TroveManager tm = new TroveManager(token, staker);
        Borrower borrower = new Borrower();
        token.mint(address(staker), 6 ether);
        tm.addCollateralSurplus(address(borrower), 6 ether);
        borrower.claimFixed(tm, address(this));
        assertEq(token.balanceOf(address(this)), 6 ether, "borrower received 6");
        assertEq(token.balanceOf(address(staker)), 0, "staker empty");
    }
}
