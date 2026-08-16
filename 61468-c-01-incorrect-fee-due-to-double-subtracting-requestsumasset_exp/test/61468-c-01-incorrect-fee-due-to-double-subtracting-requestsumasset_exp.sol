// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, HyperEvmVault, VaultEscrow, MiniToken} from "./61468-c-01-incorrect-fee-due-to-double-subtracting-requestsumasset.sol";

// Blueberry HyperEvmVault C-01 (finding 61468): `_calculateFee` subtracts
// `$.requestSum.assets` from `grossAssets`, but `grossAssets` came straight from
// `_totalEscrowValue`, which already subtracted it -> the management fee is
// levied on a doubly-reduced value. TVL 1000e18, pending 400e18, 2% annual fee,
// one year elapsed: correct fee 12e18, buggy fee 4e18, protocol shorted 8e18.
contract Finding61468Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_doubleSubtract_underchargesFee() public {
        vm.warp(400 days); // ensure block.timestamp > ONE_YEAR so run() can set lastFeeCollectionTimestamp = now - ONE_YEAR

        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("grossAssets (already minus pending)", e.grossAssetsValue());
        emit log_named_uint("fee correct (single subtract)", e.feeCorrect());
        emit log_named_uint("fee buggy (double subtract)", e.feeBuggy());
        emit log_named_uint("shortfall (protocol loss)", e.shortfall());

        assertEq(e.grossAssetsValue(), 600e18, "grossAssets = TVL - pending");
        assertEq(e.feeCorrect(), 12e18, "correct annual fee = 2% of 600e18");
        assertEq(e.feeBuggy(), 4e18, "buggy fee = 2% of doubly-reduced 200e18");
        assertLt(e.feeBuggy(), e.feeCorrect(), "fee is undercollected");
        assertEq(e.shortfall(), 8e18, "protocol shorted a full fee on the 400e18 pending amount");
        assertEq(e.token().balanceOf(SINK), 8e18, "SINK credited the fee-shortfall harm magnitude");
    }
}
