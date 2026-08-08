// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, VepochFixed, MiniToken} from "./59895-calling-withdrawforfeit-multiple-times-for-a-single-deposi.sol";

contract Vepoch59895Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_multiStepForfeit_overpays() public {
        Exploit e = new Exploit();
        e.run();

        // A single full forfeit costs 100e18; the two-step forfeit costs 150e18.
        assertEq(e.fairPaid(), 100e18, "single full forfeit reference");
        assertEq(e.totalPaidMultiStep(), 150e18, "multi-step forfeit total");
        assertEq(e.excess(), 50e18, "over-payment");

        // The concrete harm: 50e18 rewardToken over-paid, recorded at SINK.
        assertEq(e.marker().balanceOf(SINK), 50e18, "harm marker at SINK");
    }

    function test_control_fixedForfeit_noOverpay() public {
        MiniToken rewardToken = new MiniToken("EPOCH-RWD");
        VepochFixed vepoch = new VepochFixed(rewardToken);

        rewardToken.mint(address(this), 200e18);
        rewardToken.approve(address(vepoch), type(uint256).max);

        // Same deposit inputs as the exploit.
        vepoch.seedDeposit(1, 100e18, 0, 100e18);

        // Same two-step partial forfeit sequence.
        vepoch.withdrawForfeit(1, 0.5e18);
        vepoch.withdrawForfeit(1, 1e18);

        // With the fix the reward base is scaled each step: 50e18 + 50e18 = 100e18,
        // identical to a single full forfeit. No excess is charged.
        assertEq(vepoch.totalForfeitPaid(), 100e18, "fixed: no over-payment");
        assertEq(vepoch.staked(1), 0, "deposit fully unlocked");
        assertEq(vepoch.rewardTokensClaimed(1), 0, "reward base fully drained");
    }
}
