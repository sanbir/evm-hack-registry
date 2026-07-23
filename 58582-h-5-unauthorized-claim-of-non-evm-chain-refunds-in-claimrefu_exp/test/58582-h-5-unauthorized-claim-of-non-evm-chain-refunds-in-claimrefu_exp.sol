// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58582-h-5-unauthorized-claim-of-non-evm-chain-refunds-in-claimrefu.sol";

contract DodoClaimRefundAuthTest is Test {
    function test_exploit_nonEvmRefundStolen() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 10_000 ether);
        assertEq(e.token().balanceOf(address(e)), 10_000 ether);
        assertEq(e.token().balanceOf(address(e.gateway())), 0);
    }

    function test_control_evmRefundProtected() public {
        MockERC20 token = new MockERC20("T");
        GatewayCrossChain gateway = new GatewayCrossChain();
        address legitimate = address(0xBEEF);
        bytes32 id = keccak256("evm-refund");
        bytes memory evmWallet = abi.encodePacked(legitimate); // 20 bytes
        uint256 amount = 100 ether;

        token.mint(address(this), amount);
        token.approve(address(gateway), amount);
        gateway.seedRefund(id, address(token), amount, evmWallet);

        address attacker = address(0x999);
        vm.prank(attacker);
        vm.expectRevert(bytes("INVALID_CALLER"));
        gateway.claimRefund(id);

        // Legitimate EVM user can claim.
        vm.prank(legitimate);
        gateway.claimRefund(id);
        assertEq(token.balanceOf(legitimate), amount);
    }
}
