// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30561-h-03-when-decentbridgeexecutorexecute-fails-funds-will-be-se.sol";

/* Decent H-03 — failed execute refunds source-adapter address, funds lost */
contract PoC_30561 is Test {
    function test_failed_execute_refunds_wrong_address() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.weth().balanceOf(address(e.sourceAdapter())), e.AMOUNT());
        assertEq(e.weth().balanceOf(e.user()), 0);
    }
}
