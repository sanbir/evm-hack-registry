// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65583-circular-slippage-protection-in-sablierlidoadapter-wstethtow.sol";

/*//////////////////////////////////////////////////////////////
    Sablier Bob Escrow — Circular slippage in _wstETHToWeth.
    Finding #65583 (Cyfrin, MrPotatoMagic) HIGH.

    Drives the synthetic Exploit and re-asserts the harm: a 4% pool
    manipulation permanently reduces _wethReceivedAfterUnstaking; the
    attacker captures the 4 WETH sandwich profit; the circular minEthOut
    check does not revert.
//////////////////////////////////////////////////////////////*/
contract Sablier65583Test is Test {
    Exploit exploit;

    function setUp() public {
        vm.warp(0x65b0a380);
        exploit = new Exploit();
    }

    /// @notice Control: without pool manipulation, unstake pays 1:1 and
    ///         the attacker earns no sandwich profit.
    function test_control_noManipulation_fullWethReceived() public {
        MockWETH steth = new MockWETH();
        MockWETH weth = new MockWETH();
        MockCurvePool curve = new MockCurvePool(steth, weth);
        MockWstETH wsteth = new MockWstETH(steth);
        SablierLidoAdapter adapter = new SablierLidoAdapter(wsteth, weth, steth, curve);
        SablierBob bob = new SablierBob(adapter);
        adapter.setSablierBob(address(bob));
        curve.setSandwichRecipient(address(this));

        adapter.seedVault(1, 100 ether);
        // No manipulation.
        bob.unstakeTokensViaAdapter();

        assertEq(adapter.getWethReceivedAfterUnstaking(1), 100 ether);
        assertEq(weth.balanceOf(address(this)), 0); // no sandwich profit
        assertEq(weth.balanceOf(address(bob)), 100 ether);
    }

    /// @notice HARM: sandwich depresses vault WETH by 4%; attacker profits 4 WETH.
    function test_run_sandwichOnUnstaking() public {
        exploit.run();

        assertEq(exploit.adapter().getWethReceivedAfterUnstaking(1), 96 ether);
        assertEq(exploit.weth().balanceOf(address(exploit)), 4 ether);
        // Bob only holds the depressed amount for users.
        assertEq(exploit.weth().balanceOf(address(exploit.bob())), 96 ether);
    }
}
