// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./54896-incorrect-ft-reserve-used-in-buytoken-leads-to-incorrect-ft.sol";

contract Finding54896Test is Test {
    function test_exploit_issues_100_ft_of_extra_debt() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.gt().balanceOf(address(e)), 160 ether, "debt");
        assertEq(e.ft().balanceOf(address(e)), 150 ether, "ft");
        assertEq(e.router().issued(), 160 ether, "issued");
    }

    function test_control_real_balance_issues_only_60() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.gt().balanceOf(address(e)), 60 ether, "debt");
        assertEq(e.ft().balanceOf(address(e)), 150 ether, "ft");
    }
}
