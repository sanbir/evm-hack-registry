// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Honest} from "./51909-incorrect-function-call-leads-to-loss-of-claim-router-assets.sol";

contract Finding51909Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_repay_credits_60() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.connector().heldAfter(), 60 ether, "blueprint holds 60");
        assertEq(e.connector().concreteDebt(), 0, "debt cleared");
        assertEq(e.connector().routerLeft(), 0, "router drained");
        assertEq(e.funds().requested(), 30 ether, "request pulled 30");
        assertEq(e.funds().repaid(), 0, "repay was not called");
        assertEq(e.token().balanceOf(SINK), 60 ether, "60 credited");
    }

    function test_control_repay_forwards_30() public {
        (uint256 connectorLeft, uint256 routerBal, uint256 repaid, uint256 requested) = new Honest().run();
        assertEq(connectorLeft, 0, "payment left the blueprint");
        assertEq(routerBal, 60 ether, "router holds its 30 plus the repayment");
        assertEq(repaid, 30 ether, "repay pushed 30");
        assertEq(requested, 0, "request did not run");
    }
}
