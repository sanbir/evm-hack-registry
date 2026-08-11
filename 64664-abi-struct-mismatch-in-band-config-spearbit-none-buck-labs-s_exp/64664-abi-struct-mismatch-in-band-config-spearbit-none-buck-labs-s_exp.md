# Buck Labs: The BandConfig struct mismatch makes LiquidityWindow ABI-decode floorBps from PolicyManage

> **Vulnerability classes:** vuln/theft
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/64664-abi-struct-mismatch-in-band-config-spearbit-none-buck-labs-s.md -->

## Root cause

The BandConfig struct mismatch makes LiquidityWindow ABI-decode floorBps from PolicyManager's deviationThresholdBps (25 bps) instead of the real floorBps (100 bps), so requestRefund lets a refunder over-drain 7,500 USDC (75 bps of supply) of reserves below the intended floor to the attacker EOA.

```solidity

    address public policyManager;
    MiniToken public reserveToken;
    uint256 public totalTokenSupply;
    uint256 public reserves;

```

## Why it's exploitable here

The BandConfig struct mismatch makes LiquidityWindow ABI-decode floorBps from PolicyManager's deviationThresholdBps (25 bps) instead of the real floorBps (100 bps), so requestRefund lets a refunder over-drain 7,500 USDC (75 bps of supply) of reserves below the intended floor to the attacker EOA.

## Attack path

```mermaid
flowchart TD
  S0["Fetch band config from PolicyManager"]
  S1["Compute reserve floor from config"]
  S2["Fixed liquidity window contract"]
  S3["Supply base for floor collapse"]
  S4["Wire reserve token"]
  H["The BandConfig struct mismatch makes LiquidityWindow ABI-decode floorB"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L172** — Fetch band config from PolicyManager: Reads the current band's config from PolicyManager and ABI-decodes it into the local `BandConfig` struct.
2. **L173** — Compute reserve floor from config: Derives the reserve floor from the decoded config — the level refunds must not drain reserves below.
3. **L187** — Fixed liquidity window contract: Setup: the patched variant whose `BandConfig` layout matches PolicyManager, decoding the true 100-bps floor.
4. **L192** — Supply base for floor collapse: Root-cause bug: the mismatched `BandConfig` layout decodes `floorBps` from the 25-bps `deviationThresholdBps`, collapsing the reserve floor so refunds over-drain.
5. **L197** — Wire reserve token: Setup: constructor stores the reserve token that refunds are paid out of.
6. **L198** — Store total token supply: Setup: records the token supply the floor's basis-points are applied against.
7. **L202** — Floor calc reads BandConfig: Computes the floor from a `PolicyManager.BandConfig` — the exact struct whose field mismatch feeds the wrong `floorBps`.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 64664-abi-struct-mismatch-in-band-config-spearbit-none-buck-labs-s_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **The BandConfig struct mismatch makes LiquidityWindow ABI-decode floorBps from PolicyManager's deviationThresholdBps (25 bps) instead of the **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
