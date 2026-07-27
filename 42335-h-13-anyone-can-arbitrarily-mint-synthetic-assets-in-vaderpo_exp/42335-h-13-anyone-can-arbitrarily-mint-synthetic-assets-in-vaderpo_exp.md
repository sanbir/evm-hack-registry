# VaderPoolV2 `mintSynth` accepts a victim as transfer source

The test executes the real vulnerable `VaderPoolV2.mintSynth` and `Synth` sources vendored under `src/vader/`. A caller supplies another account as the source and the test verifies the unauthorized synth mint path.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42335](https://github.com/Auditware/AuditVault/blob/main/findings/42335-h-13-anyone-can-arbitrarily-mint-synthetic-assets-in-vaderpo.md), [Vader repository](https://github.com/vaderprotocol/vaderprotocol).
