# Y2K rollover queue griefing

The test runs the historical Y2K `VaultV2`/`Carousel` implementation vendored under `src/v2/`. It fills the real rollover queue in the audited order and asserts the later-user griefing behavior; no replacement vault logic is used.

```bash
forge test -vvv
```

Sources: [Sherlock Y2K report](https://github.com/sherlock-audit/2023-03-Y2K-judging), [AuditVault finding #18534](https://github.com/Auditware/AuditVault/blob/main/findings/18534-h-2-earlier-users-in-rollover-queue-can-grief-later-users-sh.md).
