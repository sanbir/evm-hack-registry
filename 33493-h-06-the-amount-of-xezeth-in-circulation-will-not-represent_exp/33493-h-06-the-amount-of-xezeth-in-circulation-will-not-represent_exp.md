# Renzo xRenzoDeposit: stale L2 price makes xezETH supply under-backed

This POC uses the real Renzo L2 bridge source from the Code4rena 2024-04
snapshot (`.poc-sources/2024-04-renzo`, commit
`b5b5b76aeafd26c3607d1f0cda6835934d9e7b9e`). The exact `xRenzoDeposit` source
is compiled; Connext, tokens, and the oracle are boundary-compatible doubles.

The user deposits at the initial 1.0 exchange rate, receiving xezETH. The test
then follows the production owner price update path eight times (the source
limits each update to a 10% step) until the L2 price is about 2.14. The old
minted supply remains unchanged while the amount represented at the new price
is less than half, demonstrating the accounting mismatch that the bridge's
cross-chain reconciliation must handle.

## Reproduction

```bash
cd 33493-h-06-the-amount-of-xezeth-in-circulation-will-not-represent_exp
forge test -vvv
```

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/33493-h-06-the-amount-of-xezeth-in-circulation-will-not-represent.md -->
