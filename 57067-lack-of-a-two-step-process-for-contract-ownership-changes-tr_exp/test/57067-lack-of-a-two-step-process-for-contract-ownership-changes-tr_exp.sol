// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, HotOwner, Vault} from "./57067-lack-of-a-two-step-process-for-contract-ownership-changes-tr.sol";

contract VaultFixed is Vault {
    constructor(Token token_, address owner_) Vault(token_, owner_) {}

    function transferOwnership(address newOwner) external override onlyOwner {
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending");
        owner = msg.sender;
    }
}

contract Finding57067Test is Test {
    function test_exploit_becomes_owner_and_pulls_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000, "attacker pulled 1000");
        assertEq(e.vault().owner(), address(e), "attacker is owner");
    }

    function test_control_attacker_cannot_complete_two_steps() public {
        Token token = new Token();
        HotOwner hot = new HotOwner();
        VaultFixed vault = new VaultFixed(token, address(hot));
        token.mint(address(vault), 1000);
        address guardian = address(0xBEEF);

        hot.handOff(address(vault), address(this));
        hot.handOff(address(vault), guardian);
        (bool accepted,) = address(vault).call(abi.encodeWithSelector(VaultFixed.acceptOwnership.selector));
        (bool swept,) = address(vault).call(abi.encodeWithSelector(Vault.sweep.selector));

        assertFalse(accepted, "attacker cannot accept");
        assertFalse(swept, "attacker cannot sweep");
        assertEq(vault.owner(), address(hot), "owner unchanged");
        assertEq(vault.pendingOwner(), guardian, "pending is the guardian");
        assertEq(token.balanceOf(address(this)), 0, "control pays 0");
        assertEq(token.balanceOf(address(vault)), 1000, "1000 stays in the vault");
    }
}
