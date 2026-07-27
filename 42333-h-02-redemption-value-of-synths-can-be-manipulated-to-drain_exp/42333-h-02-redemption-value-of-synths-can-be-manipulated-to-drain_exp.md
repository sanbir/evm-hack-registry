# VaderPool synth redemption price manipulation

This POC runs the exact vulnerable Vader `VaderPoolV2`/synth source vendored under `src/vader/`. It follows the real spot-price and redemption calls with a manipulated pool state and observes the native-asset drain path.

```bash
forge test -vvv
```

Sources: [AuditVault finding #42333](https://github.com/Auditware/AuditVault/blob/main/findings/42333-h-02-redemption-value-of-synths-can-be-manipulated-to-drain.md), [Vader repository](https://github.com/vaderprotocol/vaderprotocol).
