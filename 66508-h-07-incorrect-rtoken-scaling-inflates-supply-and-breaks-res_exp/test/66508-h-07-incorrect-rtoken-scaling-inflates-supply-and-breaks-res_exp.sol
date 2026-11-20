// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RTokenFixed} from
    "./66508-h-07-incorrect-rtoken-scaling-inflates-supply-and-breaks-res.sol";

contract Finding66508Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_second_deposit_is_scaled_twice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.rtoken().lastSupply(), 157.5 ether, "reports 157.5");
        assertEq(e.marker().balanceOf(SINK), 2500000000000000001, "extra supply");
    }

    function test_control_scales_the_deposit_once() public {
        RTokenFixed token = new RTokenFixed();
        token.deposit(100 ether);
        token.setIndex(1.05 ether);
        token.deposit(50 ether);
        assertEq(token.totalSupply(), 154999999999999999999, "index applied once");
    }
}
