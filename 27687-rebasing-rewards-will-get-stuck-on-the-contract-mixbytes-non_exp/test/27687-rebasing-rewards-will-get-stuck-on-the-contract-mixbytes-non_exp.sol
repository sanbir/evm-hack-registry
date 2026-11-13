// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./27687-rebasing-rewards-will-get-stuck-on-the-contract-mixbytes-non.sol";

contract FindingTest is Test {
    function test_rebase_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.storedBefore(), e.PRINCIPAL(), "stored");
        assertEq(e.liveBefore(), e.PRINCIPAL() + e.REWARD(), "live");
        assertTrue(e.removeReverted(), "reverted");
        assertEq(e.stuck(), e.PRINCIPAL() + e.REWARD(), "stuck");
        assertEq(e.lpGot(), 0, "lp");
        assertEq(e.controlGot(), e.PRINCIPAL() + e.REWARD(), "control got");
        assertEq(e.controlLeft(), 0, "control left");
        console2.log("stored");
        console2.log(e.storedBefore());
        console2.log("live");
        console2.log(e.liveBefore());
        console2.log("stuck");
        console2.log(e.stuck());
        console2.log("lp got");
        console2.log(e.lpGot());
        console2.log("control got");
        console2.log(e.controlGot());
    }
}
