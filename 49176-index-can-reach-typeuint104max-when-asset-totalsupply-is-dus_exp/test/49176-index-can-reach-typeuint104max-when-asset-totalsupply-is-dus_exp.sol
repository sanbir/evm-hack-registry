// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./49176-index-can-reach-typeuint104max-when-asset-totalsupply-is-dus.sol";

contract Finding49176Test is Test {
    function test_dust_index_locks_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.dustIndex(), uint256(type(uint104).max), "index above uint104");
        assertTrue(e.claimReverted(), "claim reverted");
        assertEq(e.stuck(), 1000 ether, "1000 stuck");
        assertEq(e.controlPaid(), 30_000_000_000_000, "control paid 3e13");
        emit log_named_uint("dust index", e.dustIndex());
        emit log_named_uint("uint104 max", uint256(type(uint104).max));
        emit log_named_uint("stuck", e.stuck());
        emit log_named_uint("control paid", e.controlPaid());
    }
}
