// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./58610-h-02-validatormanager-missing-fund-withdrawal-from-validator.sol";
contract Finding58610Test is Test {
    function test_exploit_deactivate_leaves_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.leftOnValidator(), 1_000e18, "1000 stuck");
        assertEq(e.managerReceived(), 0, "manager got nothing");
        assertEq(e.controlReceived(), 1_000e18, "control paid 1000");
        assertEq(e.controlLeft(), 0, "control validator empty");
    }
}
