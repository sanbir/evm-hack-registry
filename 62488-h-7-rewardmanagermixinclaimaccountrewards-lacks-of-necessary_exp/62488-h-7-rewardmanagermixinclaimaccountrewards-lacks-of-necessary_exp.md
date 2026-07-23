# H-7: claimAccountRewards pays MORPHO the users rewards

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62488-h-7-rewardmanagermixinclaimaccountrewards-lacks-of-necessary.md -->
<!-- date: 2025-06 -->

| Field | Value |
|-------|-------|
| Protocol | Notional Exponent |
| Severity | high |
| Source | AuditVault / https://github.com/sherlock-audit/2025-06-notional-exponent-judging |
| Harm | 100 reward tokens stolen to MORPHO address via permissionless claimAccountRewards |

## TL;DR

100 reward tokens stolen to MORPHO address via permissionless claimAccountRewards

## Vulnerable code

See the synthetic reproduction in `test/62488-h-7-rewardmanagermixinclaimaccountrewards-lacks-of-necessary.sol` — the blamed line is marked `// @> VULN`.

## Root cause

Faithful reduction of the AuditVault finding. The vulnerable line is preserved so the Playground locator points at the real bug, not scaffolding.

## Attack walkthrough

1. Deploy the reduced protocol pieces via the `Exploit` constructor.
2. `run()` performs the attack end-to-end and `require`s the harm.

## Diagrams

```mermaid
sequenceDiagram
    participant A as Attacker
    participant V as Vulnerable
    participant T as Target
    A->>V: trigger vulnerable path
    V->>V: @> VULN line executes
    V->>T: harm materializes
    A->>A: assert harm
```

## Impact

100 reward tokens stolen to MORPHO address via permissionless claimAccountRewards

## Taxonomy

- severity/high
- sector/farm
- platform/auditvault

## Sources

- AuditVault finding: https://github.com/Auditware/AuditVault/blob/main/findings/62488-h-7-rewardmanagermixinclaimaccountrewards-lacks-of-necessary.md
- Original report: https://github.com/sherlock-audit/2025-06-notional-exponent-judging
- Reduced from: sherlock-audit/2025-06-notional-exponent@82c87105 (RewardManagerMixin.claimAccountRewards)
