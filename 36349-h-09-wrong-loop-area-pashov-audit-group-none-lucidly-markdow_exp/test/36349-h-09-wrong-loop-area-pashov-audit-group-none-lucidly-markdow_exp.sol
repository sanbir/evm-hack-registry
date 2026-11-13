// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    PoolFixed
} from "./36349-h-09-wrong-loop-area-pashov-audit-group-none-lucidly-markdow.sol";

contract Finding36349Test is Test {
    function test_exploit_early_return_mints_unbacked_lp() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 181818181818181818181, "paid 2000/11 of the 1000 reserve");
        assertEq(e.mintedLp(), 200 ether, "200 LP minted");
        assertEq(e.pool().supply(), 1100 ether, "returned supply");
        assertEq(e.token().balanceOf(address(e)), 181818181818181818181, "attacker token");
        assertEq(e.pool().reserve(), 1000 ether - 181818181818181818181, "reserve left");
    }

    function test_control_brace_before_delta_does_not_pay() public {
        PoolFixed fixedPool = new PoolFixed();
        vm.expectRevert();
        fixedPool.calculate();
    }
}
