// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    PearVaultFixed
} from "./65287-h-01-forced-premature-position-liquidation-through-withdrawa.sol";

contract Finding65287Test is Test {
    function test_exploit_withdraw_liquidates_the_position() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.lost(), 50 ether, "position lost N");
        assertEq(e.vault().position(), 0, "position closed");
        assertEq(e.paid(), 100 ether, "withdrawal paid");
    }

    function test_control_withdraws_without_liquidating() public {
        Asset asset = new Asset();
        PearVaultFixed vault = new PearVaultFixed(asset);
        asset.mint(address(vault), 50 ether);
        vault.mintShares(address(this), 400 ether);

        vault.requestWithdrawal(400 ether);

        assertEq(vault.position(), 200 ether, "position untouched");
        assertEq(vault.loss(), 0, "no haircut");
        assertEq(asset.balanceOf(address(this)), 50 ether, "only liquid cash");
        assertEq(asset.balanceOf(address(vault)), 0, "liquid cash paid out");
    }
}
