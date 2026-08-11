// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BvtRewardVault,
    BvtRewardVaultFixed,
    MiniToken
} from "./62638-c-01-withdrawal-calculation-causes-underflow-locking-all-use.sol";

contract BvtWithdrawUnderflowTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER_A = address(0xAAAA);
    address internal constant USER_B = address(0xBBBB);

    uint256 internal constant STAKE = 3 ether;
    uint256 internal constant WITHDRAW_AMT = 2 ether;

    // The Exploit orchestrates the full harm: a legitimate withdraw reverts on the
    // vulnerable vault (funds locked) while the same request succeeds on the fixed
    // vault, and the locked magnitude is recorded on the LOCKED-BVT marker to SINK.
    function test_exploit_withdrawUnderflow_locksStakedPosition() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.buggyReverted(), "vulnerable withdraw must revert (arithmetic underflow)");
        assertTrue(e.fixedSucceeded(), "fixed withdraw must succeed for the same request");

        // Buggy vault kept the entire staked position: the 2 BVT the staker tried
        // to withdraw is stuck behind a permanently-reverting withdraw().
        assertEq(e.vaultBalAfterBuggy(), STAKE, "buggy vault retains the full locked position");

        // Fixed vault released exactly the requested 2 BVT.
        assertEq(e.vaultBalAfterFixed(), STAKE - WITHDRAW_AMT, "fixed vault released the withdrawal");

        // Harm marker: the locked (un-withdrawable) magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), WITHDRAW_AMT, "marker records the locked magnitude at SINK");
        assertEq(e.lockedMarker(), WITHDRAW_AMT, "locked magnitude == blocked withdrawal");
    }

    // Direct control: exercise the vulnerable vault and the fixed vault in
    // isolation with an identical seeded state, proving the ceiling division is the
    // sole cause of the underflow revert.
    function test_control_ceilingUnderflows_floorSucceeds() public {
        MiniToken bvt = new MiniToken("BeraBTC Vault Token", "BVT");
        BvtRewardVault vuln = new BvtRewardVault(address(bvt));
        BvtRewardVaultFixed fixed_ = new BvtRewardVaultFixed(address(bvt));

        address staker = address(this);
        address[] memory dUsers = new address[](3);
        dUsers[0] = staker; // self-inclusion (the bug)
        dUsers[1] = USER_A;
        dUsers[2] = USER_B;
        uint256[] memory dAmounts = new uint256[](3);
        dAmounts[0] = 1 ether;
        dAmounts[1] = 1 ether;
        dAmounts[2] = 1 ether;

        bvt.mint(address(vuln), STAKE);
        vuln.seed(staker, STAKE, dUsers, dAmounts);
        bvt.mint(address(fixed_), STAKE);
        fixed_.seed(staker, STAKE, dUsers, dAmounts);

        // Vulnerable: ceiling shares 0.667 + 0.667 + 0.667 → 3 rounded units > 2,
        // so `remainingAmount = amount - totalDelegatedAmount` underflows.
        vm.expectRevert(stdError.arithmeticError);
        vuln.withdraw(WITHDRAW_AMT);

        // Nothing withdrawn — position fully locked in the vulnerable vault.
        assertEq(bvt.balanceOf(address(vuln)), STAKE, "vulnerable vault still holds the full stake");

        // Fixed (floor): the same legitimate withdraw succeeds and releases 2 BVT.
        fixed_.withdraw(WITHDRAW_AMT);
        assertEq(bvt.balanceOf(address(fixed_)), STAKE - WITHDRAW_AMT, "fixed vault released 2 BVT");
    }
}
