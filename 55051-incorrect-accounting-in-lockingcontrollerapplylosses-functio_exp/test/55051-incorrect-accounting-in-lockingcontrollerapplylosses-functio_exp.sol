// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LockingControllerFair
} from "./55051-incorrect-accounting-in-lockingcontrollerapplylosses-functio.sol";

contract Finding55051Test is Test {
    function test_exploit_second_bucket_is_short_and_first_is_credited() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.slash(), 120 ether + 26341463414634146342, "unfair slash");
        assertEq(e.victimLeft(), 280 ether - 26341463414634146342, "bucket 1 short");
        assertEq(e.attackerExtra(), 16422881969587255612, "bucket 0 credited the extra assets");
        assertEq(e.asset().balanceOf(address(this)), 16422881969587255612, "extra assets paid to the caller");
    }

    function test_control_fair_denominator_does_not_overslash() public {
        LockingControllerFair fair = new LockingControllerFair();
        uint256 slash0 = fair.slashSecond(600 ether, 300 ether, 1000 ether);
        uint256 slash1 = fair.slashSecond(400 ether, 300 ether, 1000 ether);
        assertEq(slash0, 180 ether, "bucket 0 fair slash");
        assertEq(slash1, 120 ether, "bucket 1 fair slash");
        assertEq(slash0 + slash1, 300 ether, "fair slash equals the loss");
    }
}
