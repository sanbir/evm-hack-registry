// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38111-insolvency-in-revenuehandlersol-because-unclaimed-revenue-is.sol";

contract RevenueHandlerInsolvencyTest is Test {
    /// @notice HARM: run() proves claimable revenue doubles with no new
    ///         revenue arriving, exceeding the contract's real token balance.
    function test_exploit_claimableExceedsBalance() public {
        Exploit e = new Exploit();
        e.run();

        uint256 claimable = e.revenueHandler().claimable(address(e.token()));
        uint256 balance = e.token().balanceOf(address(e.revenueHandler()));

        assertEq(claimable, e.REV_AMOUNT() * 2, "claimable should have doubled");
        assertGt(claimable, balance, "claimable should exceed the real token balance (insolvency)");
    }

    /// @notice Isolates the exact bug: 3 checkpoints with no new revenue after
    ///         the first produce claimable = 1000, 2000, 3000 while the real
    ///         balance stays fixed at 1000 — matching the original PoC's
    ///         reported progression exactly.
    function test_buggyHandler_tripleCountsUnclaimedRevenue() public {
        MockToken token = new MockToken();
        RevenueHandler rh = new RevenueHandler(address(token));
        token.mint(address(rh), 1000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(token)), 1000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(token)), 2000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(token)), 3000 ether);

        assertEq(token.balanceOf(address(rh)), 1000 ether, "real balance never changed");
    }

    /// @notice Control: the fixed handler, which tracks the previously
    ///         checkpointed balance and only counts the NEW delta, correctly
    ///         keeps claimable == the real balance when no new revenue arrives.
    function test_control_fixedHandler_doesNotDoubleCount() public {
        MockToken token = new MockToken();
        RevenueHandlerFixed rh = new RevenueHandlerFixed(address(token));
        token.mint(address(rh), 1000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(token)), 1000 ether);

        rh.advanceEpoch();
        rh.checkpoint();
        assertEq(rh.claimable(address(token)), 1000 ether, "fixed handler should not double-count with no new revenue");
    }
}
