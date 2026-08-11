# Elytra: Missing 1e18 scale collapses tempElyAssetPrice to 2 (far below the 18-decimal oldElyAssetP

> **Vulnerability classes:** vuln/locked-funds · vuln/reward-accounting · vuln/price
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63546-h-03-scaling-error-in-elyasset-price-calculation-leads-to-fe.md -->

## Root cause

Missing 1e18 scale collapses tempElyAssetPrice to 2 (far below the 18-decimal oldElyAssetPrice 1e18), so the reward/fee branch never fires and the protocol permanently accrues 0 performance fee instead of the owed 100e18 per update.

```solidity
    function updateElyAssetPrice(uint256 totalValueInProtocol, uint256 elyAssetSupply) external {
        uint256 protocolFeeInHYPE;
        {
            uint256 tempElyAssetPrice = totalValueInProtocol / elyAssetSupply; // @> missing 1e18 scale: 18-dec/18-dec collapses price to a bare integer, always < oldElyAssetPrice
            if (tempElyAssetPrice > oldElyAssetPrice) {
                uint256 increaseInElyAssetPrice = tempElyAssetPrice - oldElyAssetPrice;
```

## Why it's exploitable here

Missing 1e18 scale collapses tempElyAssetPrice to 2 (far below the 18-decimal oldElyAssetPrice 1e18), so the reward/fee branch never fires and the protocol permanently accrues 0 performance fee instead of the owed 100e18 per update.

## Attack path

```mermaid
flowchart TD
  S0["Deploy vulnerable + fixed oracles"]
  S1["Wire the vulnerable oracle"]
  S2["Enter updateElyAssetPrice()"]
  S3["Missing 1e18 scale collapses price"]
  S4["Read back accrued fee — zero"]
  H["Missing 1e18 scale collapses tempElyAssetPrice to 2 (far below the 18-"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L130** — Deploy vulnerable + fixed oracles: Setup: deploy the buggy `ElytraOracleV1` alongside an identical fixed control, both with the same 18-decimal price state.
2. **L132** — Wire the vulnerable oracle: Setup: record the vulnerable oracle's address so the exploit can drive its price update directly.
3. **L58** — Enter updateElyAssetPrice(): Call the update with realistic 18-decimal inputs (totalValue 2000e18, supply 1000e18), a true price of 2.0.
4. **L62** — Missing 1e18 scale collapses price: Root-cause: `totalValueInProtocol / elyAssetSupply` omits the 1e18 scale, so the price is bare integer 2 instead of 2e18.
5. **L139** — Read back accrued fee — zero: Because 2 < the 18-decimal `oldElyAssetPrice` of 1e18, the reward/fee branch never fires and the accrued fee stays 0.
6. **L141** — Fixed path accrues the owed fee: The scaled fixed oracle on identical inputs computes price 2e18 and accrues the 100e18 performance fee the protocol is owed.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63546-h-03-scaling-error-in-elyasset-price-calculation-leads-to-fe_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Missing 1e18 scale collapses tempElyAssetPrice to 2 (far below the 18-decimal oldElyAssetPrice 1e18), so the reward/fee branch never fires a**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
