// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Bob,
    Exploit,
    IVault,
    MiniToken,
    OmoVaultFixed,
    Sink
} from "./53317-c-06-borrow-should-decrease-totalassets-value-pashov-audit-g.sol";

contract Finding53317Test is Test {
    function test_exploit_later_depositor_loses_the_borrowed_amount() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.inflatedBy(), 50 ether, "totalAssets high by 50");
        assertEq(e.aliceGot(), 100 ether, "first depositor withdrew 100");
        assertEq(e.bobGot(), 50 ether, "later depositor received 50");
        assertEq(e.bobLoss(), 50 ether, "later depositor lost 50");
        assertEq(e.asset().balanceOf(address(this)), 50 ether, "stolen 50 paid to caller");
        assertEq(e.asset().balanceOf(address(e.bob())), 50 ether, "bob holds 50");
    }

    function test_control_decreasing_total_assets_pays_bob_in_full() public {
        MiniToken asset = new MiniToken("OUSD");
        Sink sink = new Sink();
        OmoVaultFixed vault = new OmoVaultFixed(address(asset), address(this));
        Bob bob = new Bob(address(asset));

        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether);
        vault.borrow(50 ether, address(sink));
        assertEq(vault.totalAssets(), asset.balanceOf(address(vault)), "totalAssets matches cash");

        asset.mint(address(bob), 100 ether);
        bob.deposit(IVault(address(vault)), 100 ether);
        uint256 aliceGot = vault.withdraw(vault.sharesOf(address(this)));
        uint256 bobGot = bob.withdrawAll(IVault(address(vault)));

        assertEq(aliceGot, 50 ether, "first depositor fair claim");
        assertEq(bobGot, 100 ether, "control pays the later depositor 100");
        assertEq(asset.balanceOf(address(bob)), 100 ether, "bob whole");
    }
}
