# Base Unverified Arbitrary CALL — Allowance Drain via 0x42be3129

<!-- non-defihacklabs: Crypto Training original detection & analysis (Twitter hack alerting) -->

> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/dependency/unsafe-external-call · vuln/logic/missing-validation

---

## Key info

| | |
|---|---|
| **Loss** | **~16.623 WETH** (~$31k, SlowMist TI) |
| **Chain** | Base (8453) |
| **Vulnerable contract** | Unverified helper [`0xA31722CA2a32695280d0E7e325b3dd6d699Fc170`](https://basescan.org/address/0xa31722ca2a32695280d0e7e325b3dd6d699fc170) |
| **Victim (allowance holder)** | [`0x386218744a2053D949a1cafAE0b7B49a35e03F53`](https://basescan.org/address/0x386218744a2053d949a1cafae0b7b49a35e03f53) |
| **Attacker EOA** | [`0xBDCe6BDd52bacEaDd1fC91BF01F3bc6AB24df17A`](https://basescan.org/address/0xbdce6bdd52baceadd1fc91bf01f3bc6ab24df17a) |
| **Attacker deploy** | [`0x45e7503fAe45bED10Db4540DECf97FC8F84C15cC`](https://basescan.org/address/0x45e7503fae45bed10db4540decf97fc8f84c15cc) (from create) |
| **Primary attack tx** | [`0xe831f399…7ad7`](https://basescan.org/tx/0xe831f3991132cbaffbb4a3738da7d1e254a6c02f0adce605a333229a61e27ad7) (block **49304016**) |
| **Alert** | [SlowMist 2026-08-01](https://x.com/SlowMist_Team/status/2083509411243299252
- https://x.com/DefimonAlerts/status/2083469594526675203) |
| **Bug class** | Missing access control / unrestricted low-level CALL (selector **0x42be3129**) abusing existing ERC-20 allowance |

---

## TL;DR

1. An **unverified** Base contract holds a privileged pattern: a public function that performs a **low-level CALL** to an arbitrary target with attacker-controlled calldata (SlowMist: selector `0x42be3129`).
2. The victim had approved this helper for **~16.623 WETH**.
3. The attacker deploys a **one-shot contract** that, during construction / entry, drives the helper’s unrestricted CALL to execute `WETH.transferFrom(victim, attacker, amount)`.
4. No SC ownership of the WETH was required — only the **stale allowance** + **open CALL**.

---

## Root cause

- **Missing auth** on a helper that can perform arbitrary external calls.
- **No target / selector / calldata allowlist**.
- Combined with **ERC-20 allowance** previously granted to the helper, this is equivalent to “anyone can spend the victim’s allowance.”

---

## Attack walkthrough

1. Victim previously `approve`d WETH to `0xa317…c170` (allowance ≈ 16.623 WETH at block 49304015).
2. Attacker EOA `0xbdce…f17a` sends creation tx `0xe831…7ad7` with bytecode that embeds the victim address and WETH (`0x4200…0006`).
3. Deployed contract interacts with the unverified helper via unrestricted CALL paths (`0x42be3129` / related entrypoints).
4. `transferFrom` pulls WETH from the victim to the attacker.
5. Attacker WETH balance: **0 → 16.623029776956898128**.

---

## PoC

```bash
cd 2026-08-BaseUnverifiedArbitraryCall_a317_exp
BASE_RPC_URL=https://mainnet.base.org forge test --match-test testExploit -vvv
```

Offline: dump `anvil_state.json` after a successful fork run (see `output.txt` for `[PASS]`).

Historical create bytecode: [`calldata/attack_create.hex`](calldata/attack_create.hex).

---

## References

- https://x.com/SlowMist_Team/status/2083509411243299252
- https://basescan.org/tx/0xe831f3991132cbaffbb4a3738da7d1e254a6c02f0adce605a333229a61e27ad7
- https://basescan.org/address/0xa31722ca2a32695280d0e7e325b3dd6d699fc170
