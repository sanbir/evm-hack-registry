# Yield V2 Witch `buy`/`payAll` accepted vaults that were not under auction

> **Vulnerability classes:** vuln/logic/missing-check · vuln/defi/liquidation
>
> **Reproduction:** the test compiles and calls the historical Yield V2 `Witch` implementation, with only the Cauldron/Ladle/Join protocol boundary mocked. Both vulnerable entry points transfer the complete collateral balance while their auction records are empty.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/16980-witchs-buy-and-payall-functions-allow-users-to-buy-collatera.md -->
<!-- date: 2021-06 -->

## Root cause

The audited `Witch` source at commit `698ff848^` (the parent of Yield Protocol's fix commit `698ff848`, “draft: minimal fix for require on buy and payAll”) reads `auctions[vaultId].start` to compute the price but never checks that the timestamp is non-zero. A caller can therefore invoke liquidation-only functions for a normal vault. The fix adds `require (auctions[vaultId].start > 0, "Vault not under auction")` to both functions.

The exact historical contract is vendored at [`src/vault/Witch.sol`](src/vault/Witch.sol). Its matching interface and utility sources are vendored under `src/vault/interfaces-package` and `src/vault/utils-v2`.

## Reproduction

The fixture creates a 1,000-unit collateral / 400-unit debt vault with no auction entry, seeds the real Witch's collateral Join, and calls the real `payAll` and `buy` functions. Because `start` is zero, the historical implementation evaluates the final auction price and exits all 1,000 collateral to the caller.

```bash
cd 16980-yield-v2-witch-buy-payall-no-auction_exp
forge test -vvv
```

Expected result: `2 passed`. The assertions in [`test/16980-yield-v2-witch-buy-payall-no-auction_exp.sol`](test/16980-yield-v2-witch-buy-payall-no-auction_exp.sol) verify that the caller receives 1,000 collateral and that the vault's collateral and debt balances are reduced to zero.

## Sources

- [AuditVault finding #16980](https://github.com/Auditware/AuditVault/blob/main/findings/16980-witchs-buy-and-payall-functions-allow-users-to-buy-collatera.md)
- [Yield V2 vulnerable `Witch.sol` parent commit](https://github.com/yieldprotocol/vault-v2/tree/698ff848ac817fc677e027e8edee346232a3718a^/contracts)
- [Yield V2 fix commit `698ff848`](https://github.com/yieldprotocol/vault-v2/commit/698ff848ac817fc677e027e8edee346232a3718a)
