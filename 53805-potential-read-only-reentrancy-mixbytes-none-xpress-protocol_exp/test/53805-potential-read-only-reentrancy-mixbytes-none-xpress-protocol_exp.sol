// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53805-potential-read-only-reentrancy-mixbytes-none-xpress-protocol.sol";

contract Finding53805Test is Test {
    function test_stale_balance_lends_1000_of_the_reserve() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("lender loss", e.lenderLoss());
        console2.log("attacker", e.token().balanceOf(address(e)));
        assertEq(e.lenderLoss(), 1_000 ether, "loss");
        assertEq(e.token().balanceOf(address(e)), 2_000 ether, "got");
        assertEq(e.token().balanceOf(address(e.lender())), 0, "reserve");
    }

    function test_control_updated_balance_lends_nothing() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("lender left", e.controlLenderLeft());
        assertEq(e.controlLenderLeft(), 1_000 ether, "kept");
        assertEq(e.token().balanceOf(address(e)), 1_000 ether, "own");
    }
}
