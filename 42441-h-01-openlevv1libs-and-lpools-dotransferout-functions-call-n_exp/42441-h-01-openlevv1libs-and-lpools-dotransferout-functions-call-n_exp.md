# OpenLev native `transfer` stipend

This POC executes the historical `OpenLevV1Lib.doTransferOut` implementation vendored under `src/poc/`. The canonical Forge test in `test/42441-h-01-openlevv1libs-and-lpools-dotransferout-functions-call-n_exp.sol` funds a boundary WETH contract, invokes the real library path, and uses a contract recipient whose fallback requires more than Solidity's 2300-gas stipend. The native transfer therefore reverts exactly as reported, and the WETH backing remains escrowed.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42441](https://github.com/Auditware/AuditVault/blob/main/findings/42441-h-01-openlevv1libs-and-lpools-dotransferout-functions-call-n.md), [OpenLev repository](https://github.com/level-finance/openlev-contracts).
