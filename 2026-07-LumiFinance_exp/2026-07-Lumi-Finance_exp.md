# Lumi Finance (Sodium ERC-4337 account) — Signature-Bypass Drain

- **Date**: 2026-07-13
- **Chain**: Arbitrum One (chainid 42161)
- **Class**: ERC-4337 smart-account signature validation bypass (ERC-1271 fallback abuse)
- **PoC**: faithful on-chain replay of the two real attacker transactions on an Arbitrum fork
- **Fork block**: `483389833` (tx1 block `483389834` − 1)

## Addresses

| Role | Address |
|------|---------|
| Attacker EOA | `0xCe1a3BB0b98D0D90C7Dd0620Ab86C9A771888d88` |
| Attacker contract (unverified, on-chain) | `0x56362412AE17cac443AAFBAb4289946Ad958E8a1` |
| Sodium account impl (vulnerable, verified) | `0xb5BC46dF04dEe31D219E7664122e29EEd9506b8b` |
| EntryPoint v0.6 | `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789` |
| Example victim accounts | `0x0209d8FCB0C36399EB49E018a245C55fd37D16BD`, `0xa57A32726eba2A57102d82e0859e373bc9e03e72` (~50 victims total in tx2) |

### Drained tokens

| Token | Address | EOA gain in replay |
|-------|---------|--------------------|
| LUA (`TOK_c3aBC`) | `0xc3aBC47863524ced8DAf3ef98d74dd881E131C38` | **44,444.4152 LUA** |
| LUAUSD (`TOK_1DD6b`) | `0x1DD6b5F9281c6B4f043c02A83a46c2772024636c` | **61,512.0872 LUAUSD** |
| USD₮0 | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | drained to attack contract |
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | drained to attack contract |
| USDC.e | `0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8` | drained to attack contract |
| native ETH | — | **1.6018 ETH** |

## Attack transactions

- **tx1** (`0x630654fb1c8914405cf81bb02f091b049f19403a152f624f7b8a00c7724c6604`, block 483389834, selector `0x363e464b`): pushes UserOps through EntryPoint that make every victim Sodium account `approve()` the attacker contract for max allowance.
- **tx2** (`0x1cdba4c3f9c925e6d03ce8d07965a7521ee4e7258f6c5eeae8a7998886c2b9f0`, block 483390113, selector `0x96e676e5`): for each victim reads `balanceOf`, then `transferFrom(victim, attackerContract, balance)` for all five tokens, and finally forwards LUA + LUAUSD + ~1.6 ETH to the attacker EOA.

## Root cause — ERC-4337 signature bypass

Sodium is an ERC-4337 v0.6 smart account. Its `_validateSignature` calls
`checkValidSodiumSignature(hash, sig)`. For signature type `0x01` the account reads a 20-byte
`signer` **directly from the attacker-supplied signature blob** (`{0x01}{signer}{signatureBytes}`)
and passes it to OpenZeppelin:

```solidity
SignatureChecker.isValidSignatureNow(signer, hash, signatureBytes)
```

Because `signer` is attacker-controlled and is not the real owner:

1. `ECDSA.tryRecover(hash, signatureBytes)` returns `(address(0)/wrong, RecoverError)` **without reverting**.
2. `SignatureChecker` therefore falls back to the ERC-1271 branch: `signer.staticcall(abi.encodeWithSelector(0x1626ba7e, hash, signatureBytes))`.
3. `signer` is set to the **attacker's own contract**, which returns the ERC-1271 magic value `0x1626ba7e` → `isValidSignatureNow` returns `true`.

For the `executeWithSodiumAuthRecover` / `executeWithSodiumAuthSession` methodId branches,
`_validateSignature` then returns `0` (SIG_VALIDATION success) whenever `sessionKey == signer`
— both attacker-set. The check that should have bound the operation to the account owner instead
trusts an address embedded in the unauthenticated signature blob, so the attacker validates
arbitrary UserOps against every Sodium account and makes each one approve + get drained.

## PoC approach

`test/LumiFinance_exp.sol` forks Arbitrum at block `483389833`, then from the attacker EOA
(`vm.startPrank(EOA, EOA)` to set both `msg.sender` and `tx.origin`) calls the already-deployed
on-chain attacker contract with the two **real** calldata blobs in order (tx1 then tx2). No
attack logic is reconstructed — the exact on-chain bytes are replayed against the exact
pre-attack fork state. The test asserts the attacker EOA's LUA and LUAUSD balances strictly
increase and that total measured gains are positive.

## Result

```
[PASS] testExploit()
  Attacker EOA gain TOK_c3aBC (LUA)   : 44444.415238902046459663
  Attacker EOA gain TOK_1DD6b (LUAUSD): 61512.087280490418178501
  Attacker EOA gain native ETH        : 1.601793718853233682
```

The remaining USDC / USDC.e / USD₮0 proceeds are drained into the attacker contract
(`0x5636…`) rather than the EOA, matching the real on-chain transaction. Measured EOA profit:
**44,444.42 LUA + 61,512.09 LUAUSD + 1.6018 ETH**.

## Files

- `test/LumiFinance_exp.sol` — the replay PoC
- `basetest.sol`, `tokenhelper.sol`, `interface.sol` — harness
- `foundry.toml`, `remappings.txt`, `lib/forge-std` (symlink) — build config
- `output.txt` — passing `forge test` output
