# Harmonix Finance: Anyone front-runs finalizeSettlement() by directly transferring 1 wei of purchaseToken to 

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63977-h-02-the-finalizesettlement-can-be-dossed-leading-to-refund.md -->

## Root cause

Anyone front-runs finalizeSettlement() by directly transferring 1 wei of purchaseToken to the sale; the strict equality on the live balance never holds again, so settlement can never finalize and the entire ~600,000 purchaseToken refund pool (gated on finalization) is permanently frozen in the contract.

```solidity
        uint256 curBalance = purchaseToken.balanceOf(address(this));
        uint256 safetyBuffer = 1000;
        uint256 totalRefund = totalCommitted - totalAccepted;
        require(curBalance + safetyBuffer == totalRefund, "Settlement: total refund not matched"); // @> strict equality on the LIVE token balance: any unsolicited dust transfer to the contract makes curBalance != totalRefund - safetyBuffer, so settlement reverts forever
    }
    // ============================================================================
```

## Why it's exploitable here

Anyone front-runs finalizeSettlement() by directly transferring 1 wei of purchaseToken to the sale; the strict equality on the live balance never holds again, so settlement can never finalize and the entire ~600,000 purchaseToken refund pool (gated on finalization) is permanently frozen in the contract.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["Anyone front-runs finalizeSettlement() by directly transferring 1 wei "]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L128** — VULN step 1: strict equality on the LIVE token balance: any unsolicited dust transfer to the contract makes curBalance != totalRefund - safetyBuffer, so settlement reverts forever

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63977-h-02-the-finalizesettlement-can-be-dossed-leading-to-refund_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Anyone front-runs finalizeSettlement() by directly transferring 1 wei of purchaseToken to the sale; the strict equality on the live balance **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
