// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    OmoRouterFixed,
    OmoVault,
    VaultFactory,
    Victim
} from "./53320-h-02-the-transferfrom-in-omoroutersol-has-approval-vulnerabi.sol";

contract Finding53320Test is Test {
    function test_exploit_router_spends_victims_allowance() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1000, "1000 shares taken");
        assertEq(e.vault().balanceOf(address(this)), 1000, "caller received the shares");
        assertEq(e.vault().balanceOf(address(e.victim())), 0, "victim drained");
        assertEq(e.vault().allowance(address(e.victim()), address(e.router())), 0, "router allowance spent");
    }

    function test_control_spends_only_the_caller_allowance() public {
        OmoVault vault = new OmoVault();
        VaultFactory factory = new VaultFactory(address(vault));
        OmoRouterFixed router = new OmoRouterFixed(address(factory));
        Victim victim = new Victim();

        vault.mint(address(victim), 1000);
        victim.approve(vault, address(router), 1000);
        vault.mint(address(this), 100);
        vault.approve(address(router), 100);

        router.transferFrom(1, address(0xBEEF), 100);

        assertEq(vault.balanceOf(address(this)), 0, "caller spent their own 100");
        assertEq(vault.balanceOf(address(0xBEEF)), 100, "only the caller's shares moved");
        assertEq(vault.balanceOf(address(victim)), 1000, "victim untouched");
        assertEq(vault.allowance(address(victim), address(router)), 1000, "victim allowance unused");
        assertEq(vault.allowance(address(this), address(router)), 0, "only the caller allowance was spent");
    }
}
