// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BvtRewardVault,
    BvtRewardVaultFixed,
    BondDealerDouble,
    MiniToken
} from "./62639-h-01-users-with-level-5-account-may-bypass-the-applied-12-co.sol";

contract Level5CommissionBypassTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant RECIPIENT_COMMISSION = 0x000000000000000000000000000000000000c0Fe;
    address internal constant LEGIT_PARENT = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant DEPOSIT = 10_000 ether;
    uint256 internal constant COMMISSION = 1_200 ether; // 12%

    // ── The exploit: a Level-5 user routes the full 12% mandatory commission to
    //    their own attacker-controlled Level-5 parent; the protocol gets 0. ──
    function test_exploit_level5ParentAbsorbsFullCommission_protocolGetsZero() public {
        Exploit e = new Exploit();
        e.run();

        BvtRewardVault vault = BvtRewardVault(e.vaultAddr());

        // Attacker's Level-5 parent absorbed the entire 12% commission.
        assertEq(e.attackerParentStake(), COMMISSION, "attacker parent absorbed full 12%");
        assertEq(vault.delegatedStake(ATTACKER), COMMISSION, "vault: attacker parent stake == 1200");

        // The protocol's mandatory-commission recipient was robbed to zero.
        assertEq(e.recipientStake(), 0, "protocol recipientComission robbed to 0");
        assertEq(vault.delegatedStake(RECIPIENT_COMMISSION), 0, "vault: protocol commission == 0");

        // The diverted commission is measurable at the attacker.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(ATTACKER), COMMISSION, "marker records 1200 diverted to attacker");
    }

    // ── Negative control (same vulnerable contract, LEGITIMATE hierarchy):
    //    a parent whose commission (10%) is below the total (12%) leaves a
    //    positive residual, so the protocol IS correctly credited. This proves
    //    the theft is caused by the direct-Level-5-parent hierarchy, not the
    //    deposit math being broken for everyone. ──
    function test_control_legitimateHierarchy_protocolReceivesResidual() public {
        BondDealerDouble bd = new BondDealerDouble();
        BvtRewardVault vault = new BvtRewardVault(address(bd), RECIPIENT_COMMISSION);

        vault.addCommissionParent(LEGIT_PARENT, 4); // level 4 → 10%, below the 12% total
        vault.deposit(DEPOSIT);

        // Parent gets its 10%; the protocol gets the 2% residual — no theft.
        assertEq(vault.delegatedStake(LEGIT_PARENT), 1_000 ether, "legit parent gets its 10%");
        assertEq(vault.delegatedStake(RECIPIENT_COMMISSION), 200 ether, "protocol correctly receives 2% residual");
        assertGt(vault.delegatedStake(RECIPIENT_COMMISSION), 0, "no theft under a legitimate hierarchy");
    }

    // ── Negative control (FIXED contract): the recommended guard rejects a fresh
    //    account attaching directly to a Level-5 parent, so the theft cannot
    //    happen — no commission is diverted. ──
    function test_control_fixedVault_blocksDirectLevel5Attach() public {
        BondDealerDouble bd = new BondDealerDouble();
        BvtRewardVaultFixed vault = new BvtRewardVaultFixed(address(bd), RECIPIENT_COMMISSION);

        vault.addCommissionParent(ATTACKER, 5);
        vm.expectRevert(bytes("cannot directly attach to a Level-5 account"));
        vault.deposit(DEPOSIT);

        // The theft is blocked: nothing was diverted to the attacker parent.
        assertEq(vault.delegatedStake(ATTACKER), 0, "fixed: no commission diverted to attacker parent");
    }
}
