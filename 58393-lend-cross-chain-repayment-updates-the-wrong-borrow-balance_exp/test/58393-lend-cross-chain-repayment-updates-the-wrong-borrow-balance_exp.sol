// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./58393-lend-cross-chain-repayment-updates-the-wrong-borrow-balance.sol";

contract Finding58393Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function testFinding58393() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("same-chain debt before cross-chain repay", e.sameChainDebtBefore());
        emit log_named_uint("same-chain debt after cross-chain repay", e.sameChainDebtAfter());
        emit log_named_uint("erased same-chain debt (loss)", e.erasedDebt());

        MockERC20 token = e.token();

        // Harm: a cross-chain repayment silently wiped the borrower's SAME-CHAIN borrow slot.
        assertEq(e.sameChainDebtBefore(), 100e18, "same-chain debt should exist pre-attack");
        assertEq(e.sameChainDebtAfter(), 0, "same-chain debt wrongly erased by cross-chain repay");
        assertEq(e.erasedDebt(), 100e18, "erased magnitude");
        // Loss magnitude realized on the SINK marker.
        assertEq(token.balanceOf(SINK), 100e18, "loss magnitude not realized");
    }
}
