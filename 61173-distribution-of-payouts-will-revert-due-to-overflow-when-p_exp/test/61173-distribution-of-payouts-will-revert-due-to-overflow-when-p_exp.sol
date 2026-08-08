// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, FixedDividendManager, MiniToken} from "./61173-distribution-of-payouts-will-revert-due-to-overflow-when-p.sol";

contract Finding61173Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PAYOUT_18DEC = 20e18;
    uint256 internal constant HOLDER_BALANCE = 100;
    uint256 internal constant TOTAL_SUPPLY = 100;
    uint256 internal constant EXPECTED_BLOCKED = 20e18; // holder's pro-rata payout, permanently DoS'd

    function test_exploit_uint64_cast_overflow_dos() public {
        Exploit e = new Exploit();
        e.run();

        // The claim reverted -> irreversible DoS on the holder's payout.
        assertTrue(e.dosOccurred(), "expected SafeCast.toUint64 overflow to revert the claim");

        // The full 20e18 payout is blocked; marker records it at SINK.
        assertEq(e.blockedPayout(), EXPECTED_BLOCKED, "blocked payout magnitude mismatch");

        // Locate the marker token created last in run() (deterministic nonce 2 off the Exploit).
        MiniToken marker = MiniToken(vm.computeCreateAddress(address(e), 2));
        assertEq(marker.balanceOf(SINK), EXPECTED_BLOCKED, "marker must record the blocked payout at SINK");

        // Sanity: 20e18 truly exceeds uint64 range (the reason for the DoS).
        assertGt(EXPECTED_BLOCKED, uint256(type(uint64).max), "payout must exceed uint64.max");
    }

    function test_control_uint128_fix_allows_claim() public {
        FixedDividendManager manager = new FixedDividendManager();
        manager.setup(ATTACKER, HOLDER_BALANCE, PAYOUT_18DEC, TOTAL_SUPPLY);

        // Same attack inputs; with uint128 accounting the claim succeeds and accrues correctly.
        uint256 paid = manager.payoutBalance(ATTACKER);
        assertEq(paid, EXPECTED_BLOCKED, "fixed manager must return the full payout");

        (uint128 calculatedPayout) = manager.holderStatus(ATTACKER);
        assertEq(uint256(calculatedPayout), EXPECTED_BLOCKED, "fixed accounting must record full payout, no DoS");
    }
}
