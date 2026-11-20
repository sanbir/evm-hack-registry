// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    ConvexTradeExecutorFixed,
    Weth
} from "./13256-the-weth-tokens-are-not-taken-into-account-in-the-convextrad.sol";

contract Finding13256Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_total_funds_omits_weth() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 10 ether);
        e.run{value: 3 ether}();
        assertEq(e.exec().reported(), 28 ether, "reported");
        assertEq(e.fairTotal(), 38 ether, "fair");
        assertEq(e.omitted(), 10 ether, "omitted");
        assertEq(e.marker().balanceOf(SINK), 10 ether, "marker");
        assertEq(e.weth().balanceOf(address(e.exec())), 10 ether, "weth still there");
        console2.log("reported");
        console2.log(e.exec().reported());
        console2.log("fair");
        console2.log(e.fairTotal());
        console2.log("omitted weth");
        console2.log(e.omitted());
    }

    function test_control_total_funds_counts_weth() public {
        Weth weth = new Weth();
        ConvexTradeExecutorFixed ex = new ConvexTradeExecutorFixed(address(weth), 20 ether, 5 ether);
        weth.mint(address(ex), 10 ether);
        vm.deal(address(ex), 3 ether);
        (uint256 got,) = ex.totalFunds();
        assertEq(got, 38 ether, "fair");
        assertEq(ex.reported(), 38 ether, "stored");
        assertTrue(got != 28 ether, "not the short sum");
    }
}
