// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendBook, CrossChainRouter, FixedRouter, Usd} from
    "./58382-h-13-incorrect-debt-tracking-in-updaterepaymentstate-sherlo.sol";

contract Finding58382Test is Test {
    function test_exploit_releases_collateral_against_remaining_debt() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.book().sameChainDebt(e.borrower()), 250e18, "debt remains");
        assertEq(e.book().borrowedAssetListed(e.borrower()), false, "flag cleared");
        assertEq(e.router().trackedDebt(), 0, "tracked 0");
        assertEq(e.router().fairDebt(), 250e18, "fair 250");
        assertEq(e.usd().balanceOf(address(this)), 250e18, "250 released");
        assertEq(e.fixedRouter().trackedDebt(), 250e18, "control tracks 250");
        assertEq(e.controlBook().collateralOf(e.borrower()), 250e18, "control keeps collateral");
    }

    function test_control_keeps_the_debt_flag() public {
        Usd usd = new Usd();
        LendBook book = new LendBook(usd);
        FixedRouter fixedRouter = new FixedRouter(book);
        address borrower = address(0xB0B0);
        address underlying = address(0xA55E7);
        book.addCollateral(
            borrower,
            underlying,
            LendBook.Borrow({
                srcEid: 1,
                destEid: 2,
                principle: 100e18,
                borrowedlToken: address(0x1701),
                srcToken: underlying
            }),
            250e18,
            250e18
        );
        fixedRouter.updateRepaymentState(borrower, underlying, 100e18, 100e18, 0);
        uint256 released = book.releaseIfUnlisted(borrower, address(this));
        assertEq(fixedRouter.trackedDebt(), 250e18, "tracked 250");
        assertEq(released, 0, "nothing released");
        assertEq(book.collateralOf(borrower), 250e18, "collateral stays");
    }
}
