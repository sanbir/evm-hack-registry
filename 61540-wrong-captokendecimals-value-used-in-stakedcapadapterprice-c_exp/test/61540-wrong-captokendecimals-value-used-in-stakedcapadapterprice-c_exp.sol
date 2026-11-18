// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./61540-wrong-captokendecimals-value-used-in-stakedcapadapterprice-c.sol";

contract Finding61540Test is Test {

    function test_exploit_zero_price_redeems_underlying() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.wrongPrice(), 0, "zero");
        assertEq(e.rightPrice(), 1_000_000, "fair");
        assertEq(e.paid(), 0, "paid");
        assertEq(e.assetsOut(), 10 ether, "assets");
        assertEq(e.underlying().balanceOf(address(this)), 10 ether, "taken");
    }

}
