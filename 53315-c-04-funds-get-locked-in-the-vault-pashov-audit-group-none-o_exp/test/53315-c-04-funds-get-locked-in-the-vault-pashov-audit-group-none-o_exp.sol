// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    IRedeem,
    MiniToken,
    OmoAgent,
    OmoVaultFixed,
    Owner,
    Receiver
} from "./53315-c-04-funds-get-locked-in-the-vault-pashov-audit-group-none-o.sol";

contract Finding53315Test is Test {
    function test_exploit_redeem_to_other_receiver_locks_assets() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.topOffReverted(), "topOff reverted");
        assertEq(e.paidOut(), 0, "withdraw pays 0");
        assertEq(e.stuck(), 1000, "1000 stuck");
        assertEq(e.asset().balanceOf(address(e.vault())), 1000, "vault balance");
        assertEq(e.asset().balanceOf(address(e.receiver())), 0, "receiver got nothing");
        assertEq(e.vault().userToAccount(address(e.owner())), address(e.account()), "owner registered");
        assertEq(e.vault().userToAccount(address(e.receiver())), address(0), "receiver unregistered");
    }

    function test_control_owner_key_pays_the_receiver() public {
        MiniToken asset = new MiniToken("OUSD");
        OmoAgent account = new OmoAgent(address(this));
        OmoVaultFixed vault = new OmoVaultFixed(address(asset));
        Owner owner = new Owner(address(asset));
        Receiver receiver = new Receiver();
        vault.register(address(owner), address(account));

        asset.mint(address(owner), 1000);
        owner.fund(IRedeem(address(vault)), address(receiver), 1000);
        vault.topOff();

        assertEq(asset.balanceOf(address(receiver)), 1000, "control pays 1000");
        assertEq(asset.balanceOf(address(vault)), 0, "vault emptied");
        assertEq(vault.paid(), 1000, "paid recorded");
    }
}
