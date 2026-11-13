// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./51986-execution-fee-might-not-be-refunded-to-subaccounts-when-upda.sol";

contract Finding51986Test is Test {
    function test_execution_fee_is_not_refunded_on_update() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.feeRecorded(), e.FEE(), "fee");
        assertEq(e.buggyRefund(), 0.001 ether, "refund");
        assertEq(e.controlRefund(), 0.301 ether, "control refund");
        assertEq(e.missing(), e.FEE(), "missing");

        console2.log("fee recorded");
        console2.log(e.feeRecorded());
        console2.log("buggy refund");
        console2.log(e.buggyRefund());
        console2.log("missing refund");
        console2.log(e.missing());
    }
}
