# Accountable: An async-pending cancel leaves its redeem request queued with shares intact while pendingC

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62970-critical-dos-in-queue-processing-if-async-cancellations-are.md -->

## Root cause

An async-pending cancel leaves its redeem request queued with shares intact while pendingCancelRedeemRequest=true, so processUpToShares() permanently reverts on the _fulfillRedeemRequest cancel guard and every queued share (150 shares here: A's 50 stuck at the head + B's 100 behind it) is frozen and unclaimable.

```solidity
        if (state.pendingRedeemRequest == 0) revert NoPendingRedeemRequest();
        if (state.pendingCancelRedeemRequest) revert CancelRedeemRequestPending();

        state.pendingCancelRedeemRequest = true;

        bool canCancel = strategy.onCancelRedeemRequest(address(this), controller); // @> async strategy returns false: flag set true but the queued shares are left UN-REDUCED
```

## Why it's exploitable here

An async-pending cancel leaves its redeem request queued with shares intact while pendingCancelRedeemRequest=true, so processUpToShares() permanently reverts on the _fulfillRedeemRequest cancel guard and every queued share (150 shares here: A's 50 stuck at the head + B's 100 behind it) is frozen and unclaimable.

## Attack path

```mermaid
flowchart TD
  S0["Per-controller vault state map"]
  S1["Read pending-cancel flag"]
  S2["Cancel a queued redeem"]
  S3["Flag set, request left queued"]
  S4["Fulfill reverts on cancel guard"]
  H["An async-pending cancel leaves its redeem request queued with shares i"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L105** — Per-controller vault state map: Setup: maps each controller to its `VaultState` holding redeem and cancel flags.
2. **L127** — Read pending-cancel flag: Returns whether a controller has an async cancel pending — the flag that later blocks queue processing.
3. **L146** — Cancel a queued redeem: `cancelRedeemRequest` marks a controller's queued redeem for async cancellation.
4. **L152** — Flag set, request left queued: Root cause: sets `pendingCancelRedeemRequest=true` but leaves the request in the FIFO with shares intact, so processing later trips its own cancel guard.
5. **L167** — Fulfill reverts on cancel guard: `_fulfillRedeemRequest` reverts when it hits a request flagged pending-cancel — the guard that permanently jams `processUpToShares`.
6. **L191** — Read next queued request: `_processRequest` pulls the head request's controller, shares, and price as the queue is walked.
7. **L228** — Vault-state struct definition: Setup: declares the `VaultState` struct, including the pending-cancel flag.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62970-critical-dos-in-queue-processing-if-async-cancellations-are_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An async-pending cancel leaves its redeem request queued with shares intact while pendingCancelRedeemRequest=true, so processUpToShares() pe**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
