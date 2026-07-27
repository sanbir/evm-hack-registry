# AZTEC `confidentialApprove` signature replay

This POC runs the real vulnerable AZTEC `ZkAssetBase` snapshot immediately
before commit [`e730bde0`](https://github.com/AztecProtocol/aztec-v1/commit/e730bde00c4719f6295c0a25e7e83619ab8cff65).
That fix added `signatureLog` and rejects a non-empty signature after its first
use. The test deploys the exact historical asset bytecode and supplies only a
boundary-compatible ACE registry adapter for `createNoteRegistry`/`getNote`.

The test signs the real EIP-712 `NoteSignature` payload with a note owner's
key, submits it through a relayer, revokes the spender through the owner's
empty-signature path, and then replays the already-observed signed approval.
Because the vulnerable source has no signature-consumption mapping, the replay
restores `confidentialApproved[noteHash][spender]`.

## Reproduction

```bash
cd 16739-aztec-confidentialapprove-replay-status_exp
forge test -vvv
```

`forge build --skip test/16739-aztec-confidentialapprove-replay-status_exp.sol
--use 0.5.11 --no-auto-detect` compiles the historical source artifact; the
test itself is compiled with the current Forge test compiler and deploys that
artifact via `vm.deployCode`.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/16739-replay-attack-and-revocation-inversion-on-confidentialapprov.md -->
