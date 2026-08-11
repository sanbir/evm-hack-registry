# RipIt: acceptOffer books the offerCurrency fee into the single acceptedCurrency-denominated total

> **Vulnerability classes:** vuln/locked-funds · vuln/unfair-mint · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62542-h-05-currency-validation-missing-in-listing-and-offer-reques.md -->

## Root cause

acceptOffer books the offerCurrency fee into the single acceptedCurrency-denominated totalPendingFees scalar; an attacker offer in a worthless token inflates totalPendingFees to 2F while only F of real USDC is held, so emergencyShutdown (the only fee-withdrawal path) permanently reverts and the real F of USDC fees is locked.

```solidity
            uint256 sellerAmount = price - feeAmount;

            // Update state before external calls
            totalPendingFees += feeAmount; // @> fee booked into the single acceptedCurrency-denominated scalar while it is actually collected in offerCurrency below (no offerCurrency==acceptedCurrency check) -> phantom, unbacked fees
            // External calls after state changes
            IERC20(offers[i].request.offerCurrency).transferFrom(offers[i].request.requester, offers[i].receiver, sellerAmount);
```

## Why it's exploitable here

acceptOffer books the offerCurrency fee into the single acceptedCurrency-denominated totalPendingFees scalar; an attacker offer in a worthless token inflates totalPendingFees to 2F while only F of real USDC is held, so emergencyShutdown (the only fee-withdrawal path) permanently reverts and the real F of USDC fees is locked.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["acceptOffer books the offerCurrency fee into the single acceptedCurren"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L228** — VULN step 1: fee booked into the single acceptedCurrency-denominated scalar while it is actually collected in offerCurrency below (no offerCurrency==acceptedCurrency check) -> phantom, unbacked fees

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62542-h-05-currency-validation-missing-in-listing-and-offer-reques_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **acceptOffer books the offerCurrency fee into the single acceptedCurrency-denominated totalPendingFees scalar; an attacker offer in a worthle**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
