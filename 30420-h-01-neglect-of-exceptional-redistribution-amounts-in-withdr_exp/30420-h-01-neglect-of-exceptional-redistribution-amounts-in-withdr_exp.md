# Opus Cairo withdrawal omits exceptional redistribution amounts

This finding targets Opus Cairo (`src/core/shrine.cairo`), not an EVM Solidity contract. A Forge test cannot reproduce Cairo execution, and the earlier synthetic Solidity reduction has been removed. A Cairo-native reproduction requires the historical Opus source and Cairo toolchain.

Sources: [AuditVault finding #30420](https://github.com/Auditware/AuditVault/blob/main/findings/30420-h-01-neglect-of-exceptional-redistribution-amounts-in-withdr.md), [Code4rena Opus report](https://code4rena.com/reports/2024-01-opus).
