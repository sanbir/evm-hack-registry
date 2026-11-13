// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./49177-in-updateatoken-and-updatevariabledebttoken-of-the-lendingpo.sol";

contract Finding49177Test is Test {
    function test_wrong_reserve_index_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.storedIndex(), 224, "index word is the name offset");
        assertEq(e.reported(), 0, "wrong reserve reads 0");
        assertEq(e.fair(), 1000 ether, "fair is 1000");
        assertEq(e.offBy(), 1000 ether, "off by 1000");
        assertEq(e.controlBalance(), 1000 ether, "control reads 1000");
        emit log_named_uint("stored index", e.storedIndex());
        emit log_named_uint("reported", e.reported());
        emit log_named_uint("fair", e.fair());
        emit log_named_uint("off by", e.offBy());
    }
}
