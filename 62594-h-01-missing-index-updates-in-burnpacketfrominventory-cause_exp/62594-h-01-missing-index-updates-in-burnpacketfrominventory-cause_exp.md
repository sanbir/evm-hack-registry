# RipIt: burnPacketFromInventory swap-pops the tail packet into the burned slot but never updates t

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62594-h-01-missing-index-updates-in-burnpacketfrominventory-cause.md -->

## Root cause

burnPacketFromInventory swap-pops the tail packet into the burned slot but never updates the moved packet's _packetInventoryIdx, so a later burn of that moved packet reads a stale out-of-bounds index and reverts with Panic(0x32) — the packet becomes permanently unremovable (inventory DoS).

```solidity
        uint256 idx = _packetInventoryIdx[packetId];

        _packetInventory[packetTypeId][idx] = _packetInventory[packetTypeId][_packetInventory[packetTypeId].length - 1];
        _packetInventory[packetTypeId].pop(); // @> swap-pop removes the entry but never sets _packetInventoryIdx[movedPacket]=idx nor deletes _packetInventoryIdx[packetId] — the moved packet's index goes stale (OOB)
    }

```

## Why it's exploitable here

burnPacketFromInventory swap-pops the tail packet into the burned slot but never updates the moved packet's _packetInventoryIdx, so a later burn of that moved packet reads a stale out-of-bounds index and reverts with Panic(0x32) — the packet becomes permanently unremovable (inventory DoS).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["burnPacketFromInventory swap-pops the tail packet into the burned slot"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L79** — VULN step 1: swap-pop removes the entry but never sets _packetInventoryIdx[movedPacket]=idx nor deletes _packetInventoryIdx[packetId] — the moved packet's index goes stale (OOB)

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62594-h-01-missing-index-updates-in-burnpacketfrominventory-cause_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **burnPacketFromInventory swap-pops the tail packet into the burned slot but never updates the moved packet's _packetInventoryIdx, so a later **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
