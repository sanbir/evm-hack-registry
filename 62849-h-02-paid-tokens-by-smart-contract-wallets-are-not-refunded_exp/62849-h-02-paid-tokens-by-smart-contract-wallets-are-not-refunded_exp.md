# Etherspot: A smart-contract wallet's partial invoice payment (40e18 tokens) is permanently locked in 

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62849-h-02-paid-tokens-by-smart-contract-wallets-are-not-refunded.md -->

## Root cause

A smart-contract wallet's partial invoice payment (40e18 tokens) is permanently locked in InvoiceManager when a SETTLER cancels the stuck invoice: cancelInvoice deletes all credited-token accounting with no refund to the paying wallet, and the only exit (emergencyWithdraw) sweeps to the admin.

```solidity
    }

    // ─────────────── VERBATIM from InvoiceManager.sol L272-279 ───────────────
    // The only exit for stranded tokens: sweeps to the admin (msg.sender), NOT
    // back to the paying smart wallet. Not a refund path for the SCW.
    function emergencyWithdraw(address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
```

## Why it's exploitable here

A smart-contract wallet's partial invoice payment (40e18 tokens) is permanently locked in InvoiceManager when a SETTLER cancels the stuck invoice: cancelInvoice deletes all credited-token accounting with no refund to the paying wallet, and the only exit (emergencyWithdraw) sweeps to the admin.

## Attack path

```mermaid
flowchart TD
  S0["Declare credible-account role"]
  S1["Mark invoice open for solver"]
  S2["Grant admin role to owner"]
  S3["Credit paid tokens to invoice"]
  S4["Check if token fully paid"]
  H["A smart-contract wallet's partial invoice payment (40e18 tokens) is pe"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L124** — Declare credible-account role: Setup: defines the `CREDIBLE_ACCOUNT_ROLE` constant used to gate access on the invoice manager.
2. **L171** — Mark invoice open for solver: Records that a solver's session key now has an open invoice — the object a smart-contract wallet later pays into.
3. **L192** — Grant admin role to owner: Setup: constructor gives the owner `DEFAULT_ADMIN_ROLE`, the same role that controls the only fund-exit path.
4. **L225** — Credit paid tokens to invoice: `creditTokensToInvoice` books a paying wallet's tokens against the invoice — where the wallet's 40e18 partial payment is recorded.
5. **L251** — Check if token fully paid: Compares `creditedAmount` against the required `amount` to decide whether this invoice token line is fully settled.
6. **L283** — Cancel wipes credited accounting: `cancelInvoice` deletes the whole invoice record, erasing the wallet's credited-token balance with no refund to the payer.
7. **L307** — Only exit sweeps to admin: `emergencyWithdraw` is the sole way tokens leave, and it sends them to the admin role — never back to the locked-out payer.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62849-h-02-paid-tokens-by-smart-contract-wallets-are-not-refunded_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A smart-contract wallet's partial invoice payment (40e18 tokens) is permanently locked in InvoiceManager when a SETTLER cancels the stuck in**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
