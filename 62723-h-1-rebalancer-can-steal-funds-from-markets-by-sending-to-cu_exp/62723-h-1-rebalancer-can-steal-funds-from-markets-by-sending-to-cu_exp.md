# Malda: A semi-trusted rebalancer forwards the operator-supplied

> **Vulnerability classes:** vuln/logic
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62723-h-1-rebalancer-can-steal-funds-from-markets-by-sending-to-cu.md -->

## Root cause

A semi-trusted rebalancer forwards the operator-supplied, unchecked params.receiver to Everclear's newIntent, so 1000e18 of market funds extracted for cross-chain rebalancing are delivered to the attacker's own address instead of the destination market.

```solidity
        SafeApprove.safeApprove(params.inputAsset, address(everclearFeeAdapter), params.amount);
        (bytes32 id,) = everclearFeeAdapter.newIntent(
            params.destinations,
            params.receiver, // @> attacker-controlled receiver forwarded UNCHECKED — market funds routed to the rebalancer's own address
            params.inputAsset,
            params.outputAsset,
```

## Why it's exploitable here

A semi-trusted rebalancer forwards the operator-supplied, unchecked params.receiver to Everclear's newIntent, so 1000e18 of market funds extracted for cross-chain rebalancing are delivered to the attacker's own address instead of the destination market.

## Attack path

```mermaid
flowchart TD
  S0["Safe-approve return check"]
  S1["Bytes helper returns buffer"]
  S2["Destination chain id param"]
  S3["Rebalancing return event"]
  S4["Match requested destination"]
  H["A semi-trusted rebalancer forwards the operator-supplied, unchecked pa"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L95** — Safe-approve return check: Setup: safe-approve helper verifies the token approval call succeeded before proceeding.
2. **L141** — Bytes helper returns buffer: Setup: low-level bytes-concat helper returns the assembled buffer used to build the intent message.
3. **L240** — Destination chain id param: Setup: the target chain id for the cross-chain rebalance is passed in as `_dstChainId`.
4. **L273** — Rebalancing return event: Setup: event declaration logging funds returned to a market during rebalancing.
5. **L313** — Match requested destination: Locates the entry in the operator-supplied params matching the requested destination chain.
6. **L329** — Unvalidated receiver forwarded: Root cause: forwards `params.receiver` to `newIntent` unchecked, so extracted market funds go to the attacker's address instead of the destination market.
7. **L342** — Decode intent payload: Setup: helper that decodes an intent message back into `IntentParams`.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62723-h-1-rebalancer-can-steal-funds-from-markets-by-sending-to-cu_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A semi-trusted rebalancer forwards the operator-supplied, unchecked params.receiver to Everclear's newIntent, so 1000e18 of market funds ext**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
