# AZTEC Swap validator: missing trusted-setup pairing check

This reproduction uses the real AZTEC `Swap` validator at the vulnerable
commit [`c4448fee`](https://github.com/AztecProtocol/aztec-v1/commit/c4448fee)
(the commit removed `validatePairing(0x84)`). The test also compiles the real
follow-up source at [`e9ddc568`](https://github.com/AztecProtocol/aztec-v1/commit/e9ddc568),
which restored that check.

The proof in the test is a valid AZTEC Swap transcript (four on-curve bn128
notes, balanced maker/taker values, and a matching Fiat–Shamir challenge).
Calling the vulnerable contract with the real proof and AZTEC's fake CRS from
the original test helper succeeds. The fixed contract rejects the identical
call because its pairing precompile check detects the fake G2 setup point.

## Reproduction

```bash
cd 16736-aztec-swap-validator-missing-pairing-check_exp
forge test -vvv
```

Expected result: both tests pass. `test_vulnerable_accepts_fake_trusted_setup`
shows the missing validation; `test_fixed_rejects_same_fake_setup` is the
regression check.

Source snapshots vendored under `src/` are copied from the AZTEC repository;
there is no synthetic validator or substitute protocol logic in this POC.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/16736-missing-elliptic-curve-pairing-check-in-the-swap-validator-t.md -->
