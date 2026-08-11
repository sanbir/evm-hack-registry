# Statusl: Attacker recovers their full staked principal via the paused-revert catch path while the S

> **Vulnerability classes:** vuln/theft · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65325-malicious-actors-can-get-free-rewards-if-contract-gets-pause.md -->

## Root cause

Attacker recovers their full staked principal via the paused-revert catch path while the StakeManager still counts the phantom stake, letting them drain 50 reward tokens from the pool for free at honest stakers' expense.

```solidity
                    revert StakeVault__FailedToLeave();
                }
            }
        } catch { // @> try/catch swallows StakeManager.leave() revert: vault returns staked tokens while the manager keeps counting the stake
            if (lockUntil <= block.timestamp) {
                depositedBalance = 0;
```

## Why it's exploitable here

Attacker recovers their full staked principal via the paused-revert catch path while the StakeManager still counts the phantom stake, letting them drain 50 reward tokens from the pool for free at honest stakers' expense.

## Attack path

```mermaid
flowchart TD
  S0["Owner stakes and locks tokens"]
  S1["Exit path returns principal"]
  S2["Catch swallows paused revert"]
  S3["Require lock period expired"]
  S4["Verify principal transfer"]
  H["Attacker recovers their full staked principal via the paused-revert ca"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L158** — Owner stakes and locks tokens: Setup: `stake()` locks the owner's tokens and registers the position with the StakeManager.
2. **L166** — Exit path returns principal: Setup: `leave()` is the exit that tries to unstake from the manager and send principal to a destination.
3. **L176** — Catch swallows paused revert: Root cause: on a paused-manager revert this `catch` returns principal but leaves the phantom stake the manager still counts, so the attacker keeps free rewards.
4. **L177** — Require lock period expired: Only proceeds to return funds once the lock has elapsed (`lockUntil <= block.timestamp`).
5. **L180** — Verify principal transfer: Checks the principal transfer to the destination actually succeeded.
6. **L203** — Declare NotOwner error: Setup: declares the `StakeVault__NotOwner` custom error.
7. **L207** — Owner-only access guard: Setup: restricts vault actions to the owner via a `msg.sender != owner` check.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65325-malicious-actors-can-get-free-rewards-if-contract-gets-pause_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Attacker recovers their full staked principal via the paused-revert catch path while the StakeManager still counts the phantom stake, lettin**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
