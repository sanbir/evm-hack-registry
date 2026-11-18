// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FeeToken, Vault, UpliftOnlyExampleFixed} from
    "./49688-owner-fee-will-be-locked-in-upliftonlyexample-contract-due-t.sol";

contract Finding49688Test is Test {
    function test_exploit_owner_fee_locked_in_hook() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.hookBalance(), 1 ether, "hook holds the fee");
        assertEq(e.ownerBalance(), 0, "owner got nothing");
        assertEq(e.feeToken().balanceOf(address(e.hook())), 1 ether, "still locked");
    }

    function test_control_fee_reaches_owner() public {
        FeeToken token = new FeeToken();
        Vault vault = new Vault(token);
        address owner = address(0x0A11E5);
        UpliftOnlyExampleFixed hook = new UpliftOnlyExampleFixed(vault, owner);
        token.mint(address(vault), 1 ether);
        hook.onAfterSwap(address(token), 1 ether);
        assertEq(token.balanceOf(owner), 1 ether, "owner received the fee");
        assertEq(token.balanceOf(address(hook)), 0, "hook is empty");
    }
}
