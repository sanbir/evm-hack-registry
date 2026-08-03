# BSC MEV Vault `0xb5cb…` — Authorized Helper Arbitrary Call Drains Venus vTokens

<!-- non-defihacklabs -->

> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/dependency/unsafe-external-call

> **Reproduction:** isolated Foundry project at [this project folder](.). Verbose run: [output.txt](output.txt).
> Live attack initcode: [sources/attack_initcode.hex](sources/attack_initcode.hex).

---

## Key info

| | |
|---|---|
| **Loss** | **~$1.1M** first tx; campaign **~$2M** across follow-ups (TenArmor) |
| **Vulnerable vault** | [`0xB5CB0555C0C51e603eaD62C6437dA65372e4E1B0`](https://bscscan.com/address/0xb5cb0555c0c51e603ead62c6437da65372e4e1b0) |
| **Authorized helper** | [`0xB5CB0555c4A333543DbE0b219923C7B3e9D84a87`](https://bscscan.com/address/0xb5cb0555c4a333543dbe0b219923c7b3e9d84a87) |
| **Attacker EOA** | [`0xd5c6f3B71bCcEb2eF8332bd8225f5F39E56A122c`](https://bscscan.com/address/0xd5c6f3b71bcceb2ef8332bd8225f5f39e56a122c) |
| **Attack create** | [`0xC269cd69CcCB1BBEDB44f93c612905219F424c11`](https://bscscan.com/address/0xc269cd69cccb1bbedb44f93c612905219f424c11) |
| **Attack tx** | [`0x7708aaedf3d408c47b04d62dac6edd2496637be9cb48852000662d22d2131f44`](https://bscscan.com/tx/0x7708aaedf3d408c47b04d62dac6edd2496637be9cb48852000662d22d2131f44) |
| **Authorize tx** | [`0x0c510ce316447e76d5634cc370f13fcf2fb8e5c2519bd63df4ed0ef7378f8e42`](https://bscscan.com/tx/0x0c510ce316447e76d5634cc370f13fcf2fb8e5c2519bd63df4ed0ef7378f8e42) (`authorize(helper)`) |
| **Chain / block / date** | BSC / **52,052,493** (fork **52,052,492**) / ~Jun 25, 2025 |
| **Bug class** | Privileged vault transfer (`0x0243f5a2`) callable via an **authorized helper** with a **public entry/fallback** — effectively arbitrary call into access-controlled target |

---

## TL;DR

A Venus-integrated MEV / strategy vault (`0xb5cb…e1b0`) gates sensitive operations (including vToken transfers via selector `0x0243f5a2`) behind `isAuthorized`. Days before the drain, admin called `authorize(0xb5cb…4a87)` on the vault.

The helper is **not** a tightly scoped adapter. Its public surface (fallback / open entry) lets any external caller trigger the vault’s privileged `0x0243f5a2` path, which does:

```text
vToken.transfer(attackerChosenRecipient, amount)
```

for the vault’s Venus inventory (vUSDT, vUSDC, vETH, vBTC, …).

The live attacker packaged the multi-token drain into a **CREATE constructor** that, for each vToken:

1. Reads `vToken.balanceOf(vault)`.
2. Calls the authorized helper.
3. Helper → vault `0x0243f5a2(vToken, amount, attacker, …)`.
4. Vault transfers the full vToken balance to the attacker.

---

## Pre-attack state (fork 52,052,492)

| Asset | Vault balance (raw) |
|---|---|
| vUSDT `0xfd58…0255` | 1,630,935,807,678,191 |
| vUSDC `0xeca8…67c8` | 800,365,645,822,131 |
| vETH  `0xf508…592c8` | 329,293,631,993 |
| vBTC  `0x882c…847b` | 14,631,336,015 |
| `isAuthorized(helper)` | **true** |

---

## Attack steps (PoC)

1. Fork BSC at `52052493 - 1`.
2. Confirm `vault.isAuthorized(helper)`.
3. `CREATE` the live attack initcode (constructor arg = helper) — same bytes as tx `0x7708…1f44`.
4. Constructor drains all four vToken balances to the attacker EOA.
5. Assert vault vUSDT/vUSDC balances are zero.

Follow-up txs (`0x8c02…`, `0xf902…`) continued the campaign (~$2M total per TenArmor).

---

## Fix class

- Never `authorize` a contract with a **public arbitrary-call / open fallback**.
- Privileged transfer functions should only be callable by `msg.sender == owner` or a **timelocked multisig**, not a hot helper.
- If a helper is required, whitelist exact calldata (selector + fixed target list) and disable raw `call` / fallback forwarding.

---

## Sources

- [TenArmorAlert](https://x.com/TenArmorAlert/status/1937724816540279248)
- Follow-up: [status/1937743913433071663](https://x.com/TenArmorAlert/status/1937743913433071663)
