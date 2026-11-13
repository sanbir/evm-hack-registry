// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Rep} from "./11483-h04-user-can-unknowingly-contribute-to-the-wrong-market-outc.sol";

contract Finding11483Test is Test {
    function test_tentative_contribution_lands_on_outcome_A() public {
        Exploit e = new Exploit();
        e.run();

        Rep rep = e.rep();
        assertEq(e.wrongHash(), e.hashA(), "wrong outcome");
        assertTrue(e.hashA() != e.hashB(), "distinct");
        assertEq(e.wrongStake(), e.N(), "wrong amount");
        assertEq(rep.balanceOf(address(e.preemptiveA())), e.N(), "A holds N");
        assertEq(e.controlHash(), e.hashB(), "control outcome");
        assertEq(e.controlStake(), e.N(), "control amount");
        assertEq(rep.balanceOf(address(e.user())), 0, "user spent");

        console2.log("N credited to outcome A");
        console2.log(e.wrongStake());
        console2.log("credited hash is A");
        console2.log(e.wrongHash() == e.hashA() ? 1 : 0);
        console2.log("requested hash differs from A");
        console2.log(e.hashA() != e.hashB() ? 1 : 0);
        console2.log("control credited N to B");
        console2.log(e.controlStake());
        console2.log("A balance");
        console2.log(rep.balanceOf(address(e.preemptiveA())));
    }
}
