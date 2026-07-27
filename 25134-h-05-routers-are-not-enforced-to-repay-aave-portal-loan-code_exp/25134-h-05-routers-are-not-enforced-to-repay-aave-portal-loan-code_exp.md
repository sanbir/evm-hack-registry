# Connext portal loan is not enforced to be repaid

This POC executes the historical Connext `PortalFacet`/router code vendored under `src/connext/`. Boundary doubles implement only Aave/Connext external interfaces; the loan, router call, and repayment accounting are the real audited path.

```bash
forge test -vvv
```

Sources: [AuditVault finding #25134](https://github.com/Auditware/AuditVault/blob/main/findings/25134-h-05-routers-are-not-enforced-to-repay-aave-portal-loan-code.md), [Connext repository](https://github.com/connext/monorepo).
