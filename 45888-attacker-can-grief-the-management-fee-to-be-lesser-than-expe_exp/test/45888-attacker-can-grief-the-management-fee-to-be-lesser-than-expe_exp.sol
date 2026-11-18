// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45888-attacker-can-grief-the-management-fee-to-be-lesser-than-expe.sol";

contract Finding45888Test is Test {

    function test_exploit_zeroes_management_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.griefFee(), 0, "grief");
        assertGt(e.controlFee(), 1000 ether, "control");
        assertEq(e.grief().feesUpdatedAt(), uint64(block.timestamp), "clock");
        assertEq(e.grief().balanceOf(address(0xFEEE)), 0, "recipient");
        assertGt(e.control().balanceOf(address(0xFEEE)), 1000 ether, "honest recipient");
    }

}
