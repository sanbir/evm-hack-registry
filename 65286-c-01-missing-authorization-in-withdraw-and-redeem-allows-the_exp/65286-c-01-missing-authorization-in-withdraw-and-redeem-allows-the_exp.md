# Pear: Any caller redeems a victim's ERC4626 vault shares to themselves — victim's 1000e18 shares

> **Vulnerability classes:** vuln/theft
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65286-c-01-missing-authorization-in-withdraw-and-redeem-allows-the.md -->

## Root cause

Any caller redeems a victim's ERC4626 vault shares to themselves — victim's 1000e18 shares are burned to 0 and 1000e18 underlying is transferred to the attacker EOA, draining all depositors.

```solidity
    function _withdrawWithFee(uint256 shares, address user, address receiver) internal returns (uint256) {
        // code
        uint256 assetsToTransfer = super.previewRedeem(shares); // fee == 0 -> full asset value
        super._withdraw(
            user, // @> caller (same as owner to avoid allowance check) -> super._withdraw skips _spendAllowance, so ANY attacker may pass a victim as `user`
            receiver, // receiver
```

## Why it's exploitable here

Any caller redeems a victim's ERC4626 vault shares to themselves — victim's 1000e18 shares are burned to 0 and 1000e18 underlying is transferred to the attacker EOA, draining all depositors.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  S1["VULN step 2"]
  H["Any caller redeems a victim's ERC4626 vault shares to themselves — vic"]
  S0 --> S1
  S1 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L254** — VULN step 1: caller (same as owner to avoid allowance check) -> super._withdraw skips _spendAllowance, so ANY attacker may pass a victim as `user`
2. **L257** — VULN step 2: caller (same as owner to avoid allowance check) -> super._withdraw skips _spendAllowance, so ANY attacker may pass a victim as `user`

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65286-c-01-missing-authorization-in-withdraw-and-redeem-allows-the_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Any caller redeems a victim's ERC4626 vault shares to themselves — victim's 1000e18 shares are burned to 0 and 1000e18 underlying is transfe**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
