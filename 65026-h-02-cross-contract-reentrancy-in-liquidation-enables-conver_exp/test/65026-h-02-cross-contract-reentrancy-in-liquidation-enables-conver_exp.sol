// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65026-h-02-cross-contract-reentrancy-in-liquidation-enables-conver.sol";

contract PhantomShareReentrancyTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // fund exploit with 1 wei for liquidation refund path
        vm.deal(address(e), 1 wei);
        e.run();

        assertEq(e.stolen(), 1000e18, "drained vault assets");
        assertEq(e.token1().balanceOf(address(e.liquidator())), 1000e18);
        assertEq(e.token1().balanceOf(address(e.ct1())), 0);
    }
}
