# VaderPoolV2 `mintFungible` accepts a victim as transfer source

The test executes the real vulnerable `VaderPoolV2.mintFungible` source vendored under `src/vader/`. A caller supplies another account as the source and the test verifies unauthorized fungible-token minting.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42336](https://github.com/Auditware/AuditVault/blob/main/findings/42336-h-14-anyone-can-arbitrarily-mint-fungible-tokens-in-vaderpoo.md), [Vader repository](https://github.com/vaderprotocol/vaderprotocol).
