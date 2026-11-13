// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./52869-distributefor-might-be-reentered-leading-to-the-loss-of-bgt.sol";

contract Finding52869Test is Test {
    function test_reentered_distribute_pays_the_whole_bgt_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.drained(), e.POOL(), "drained");
        assertEq(e.rounds(), 5, "rounds");
        assertEq(e.controlPaid(), e.PAY(), "control");
        assertEq(e.extra(), 400 ether, "extra");

        console2.log("bgt drained");
        console2.log(e.drained());
        console2.log("rounds");
        console2.log(e.rounds());
        console2.log("control paid");
        console2.log(e.controlPaid());
    }
}
