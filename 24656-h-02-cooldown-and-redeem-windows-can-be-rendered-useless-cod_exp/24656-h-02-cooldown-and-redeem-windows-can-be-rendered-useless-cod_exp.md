# Notional sNOTE: audit path checked against the exact snapshot

This target uses the real Notional `sNOTE` source from the 2022-01 Code4rena
snapshot (`.poc-sources/2022-01-notional`, commit
`4419fe395384bd9346a86070e78d274cb0aa6a37`). The Balancer vault and ERC-20s
are boundary-compatible test doubles; cooldown, mint, and redeem logic is the
real contract code.

The Code4rena finding describes starting a cooldown with no sNOTE, waiting for
the redemption window, then depositing and redeeming. That sequence does not
execute against this exact source: `_beforeTokenTransfer` checks the recipient
on mint and reverts while the account window is active. After the window ends,
minting succeeds but the expired window rejects redemption. The test is kept as
a regression check so this target does not claim a fabricated exploit.

## Verification

```bash
cd 24656-h-02-cooldown-and-redeem-windows-can-be-rendered-useless-cod_exp
forge test -vvv
```

The test passes when the exact `startCoolDown`, `mintFromBPT`, and `redeem`
path rejects the reported sequence. The original finding and the later
discussion questioning its exploit path are linked below.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/24656-h-02-cooldown-and-redeem-windows-can-be-rendered-useless-cod.md -->
<!-- c4-issue: https://github.com/code-423n4/2022-01-notional-findings/issues/68 -->
