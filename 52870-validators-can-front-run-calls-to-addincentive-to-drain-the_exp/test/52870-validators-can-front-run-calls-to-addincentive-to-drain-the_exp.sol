// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./52870-validators-can-front-run-calls-to-addincentive-to-drain-the.sol";

contract Finding52870Test is Test {
    function test_front_run_pins_max_rate_and_one_block_takes_the_pot() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rateAfterSandwich(), e.MAX_RATE(), "rate");
        assertEq(e.drained(), e.ATTACK_AMT() + e.VICTIM_AMT(), "drained");
        assertEq(e.fairPaid(), 50 ether, "fair");
        assertEq(e.extra(), 100_051 ether, "extra");

        console2.log("drained");
        console2.log(e.drained());
        console2.log("fair paid");
        console2.log(e.fairPaid());
        console2.log("extra");
        console2.log(e.extra());
    }
}
