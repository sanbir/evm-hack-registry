// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit} from "./29874-l1blastbridge-uses-wrong-token-order-when-bridging-usd-yield.sol";

contract Finding29874Test is Test {
    function test_exploit_userReceivesDaiInsteadOfUsdb() public {
        Exploit e = new Exploit();
        e.run();

        console.log("user DAI", e.receivedDai());
        console.log("user USDB", e.receivedUsdb());
        console.log("bridge DAI left", e.dai().balanceOf(address(e.l2())));
        console.log("bridge USDB left", e.usdb().balanceOf(address(e.l2())));

        assertEq(e.receivedDai(), 1000 ether, "DAI received");
        assertEq(e.receivedUsdb(), 0, "USDB received");
        assertEq(e.l2().paidLocal(), address(e.dai()), "local");
        assertEq(e.l2().paidRemote(), address(e.usdb()), "remote");
        assertEq(e.dai().balanceOf(address(e)), 1000 ether, "exploit DAI");
        assertEq(e.usdb().balanceOf(address(e)), 0, "exploit USDB");
        assertEq(e.usdb().balanceOf(address(e.l2())), 1000 ether, "USDB stuck on L2");
        assertEq(e.dai().balanceOf(address(e.l2())), 0, "DAI left L2");
    }

    function test_control_correctOrderPaysUsdb() public {
        Exploit e = new Exploit();
        e.control(address(this));

        assertEq(e.usdb().balanceOf(address(this)), 1000 ether, "control USDB");
        assertEq(e.dai().balanceOf(address(this)), 0, "control DAI");
        assertEq(e.l2().paidLocal(), address(e.usdb()), "control local");
        assertEq(e.l2().paidRemote(), address(e.dai()), "control remote");
        assertEq(e.l2().paidAmount(), 1000 ether, "amount");
    }
}
