<!-- non-defihacklabs -->
# QNT Reserve EIP-7702 + Permissionless `BatchCall.batch()` Drain

> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/access-control/broken-logic · vuln/dependency/unsafe-external-call

> **Reproduction:** the PoC compiles & runs in an isolated Foundry project at
> [this project folder](.). The fork is served offline from the bundled
> `anvil_state.json` (local anvil replays Ethereum state at block `24978302`), so no
> public RPC is required.
> Full verbose trace: [output.txt](output.txt).
> Reconstructed BatchCall surface: [BatchCall.sol](sources/batchcall/BatchCall.sol)
> (on-chain BatchCall is **unverified**; source is reconstructed from selectors /
> dispatch — the critical property is the **absence** of any caller auth on `batch()`).

---

## Key info

| | |
|---|---|
| **Loss** | **1,988.546547972979064297 QNT** (exact wei: `1988546547972979064297`) → swapped to **~54.93 ETH** |
| **Vulnerable contract** | BatchCall — [`0x044dc3e39c566a95011e272ec800dbd2cc9c057c`](https://etherscan.io/address/0x044dc3e39c566a95011e272ec800dbd2cc9c057c) (permissionless `batch`) |
| **Admin EOA (EIP-7702)** | [`0xc6ddf90790b433743bd050c1d1d45f673a3413f4`](https://etherscan.io/address/0xc6ddf90790b433743bd050c1d1d45f673a3413f4) |
| **7702 delegate (BatchExecutor)** | [`0x95538e1c40e82dbc9dfb2f7f88580d0d0824688e`](https://etherscan.io/address/0x95538e1c40e82dbc9dfb2f7f88580d0d0824688e) |
| **QNT reserve wallet** | [`0x9510facf9e83f6e615ffb7bf11010ddb065da153`](https://etherscan.io/address/0x9510facf9e83f6e615ffb7bf11010ddb065da153) |
| **QNT token** | [`0x4a220E6096B25EADb88358cb44068A3248254675`](https://etherscan.io/address/0x4a220E6096B25EADb88358cb44068A3248254675) |
| **Attacker EOA** | [`0xe6dE6836F3fDC9ea186E267634DCa95a4a3672eF`](https://etherscan.io/address/0xe6dE6836F3fDC9ea186E267634DCa95a4a3672eF) |
| **Attack contract** | [`0xf2108E4C4472ab542e90bE5e8D8E258F50c4de56`](https://etherscan.io/address/0xf2108E4C4472ab542e90bE5e8D8E258F50c4de56) (CREATE in attack tx, nonce 0) |
| **Intermediate** | [`0x5a81Ea5eC89571C78b4B3a8E7a1207914C8179fD`](https://etherscan.io/address/0x5a81Ea5eC89571C78b4B3a8E7a1207914C8179fD) (CREATE by attack contract, nonce 1) |
| **Attack tx** | [`0x4f31f68d…`](https://etherscan.io/tx/0x4f31f68df9f240492f13df9ab23207ea231ec1b5a89af9c31cde58e7d98cb18c) (entire drain in constructor) |
| **Chain / block / date** | Ethereum mainnet / fork `24978302` (attack in `24978303`) / ~2026-04-29 |
| **Bug class** | Permissionless batch executor × EIP-7702-delegated privileged EOA |
| **Alert** | [SlowMist TI](https://x.com/SlowMist_Team/status/2049333031371210854) |

---

## TL;DR

1. A QNT reserve is controlled under the authority of admin EOA
   `0xc6ddf907…`.
2. That EOA is **EIP-7702-delegated** to BatchExecutor
   `0x95538e1c…` (designator code `0xef0100 || delegate`).
3. BatchExecutor exposes `BATCHER() = BatchCall 0x044dc3…` and treats that
   BatchCall as an authorized owner (`isOwner(BatchCall) == true`).
4. **`BatchCall.batch(address[],bytes[])` has no caller auth** — any EOA can
   supply targets + calldatas.
5. Attacker CREATE (nonce 0) constructor drives the open batch path, transfers
   **all 1,988.5465 QNT** out of the reserve wallet, multi-hop swaps, and
   realizes **~54.93 ETH** on the attacker EOA.

This is a **smart-contract access-control bug** (open `batch`) **composed with**
a dangerous 7702 admin setup — not pure private-key theft. Once the EOA
delegated to the bad executor design, **any** caller could invoke the open batch
path in the admin's authority.

---

## Root cause (both layers)

### Layer 1 — EIP-7702 admin delegation

At fork block `24978302`, admin code is the 23-byte EIP-7702 designator:

```text
0xef010095538e1c40e82dbc9dfb2f7f88580d0d0824688e
│     └─ 20-byte BatchExecutor address
└─ EIP-7702 designator prefix
```

Calls to the admin EOA execute BatchExecutor code with `address(this) == admin`.

BatchExecutor getters (immutable / view) at that block:

| Getter | Value |
|--------|--------|
| `BATCHER()` | `0x044DC3e39c566A95011E272Ec800dBd2cc9c057C` (BatchCall) |
| `isOwner(BatchCall)` | `true` |
| `DESTINATION()` | another 7702-delegated EOA |

### Layer 2 — Permissionless `BatchCall.batch()`

BatchCall is **unverified**. Runtime dispatch exposes:

- `batch(address[],bytes[])` = `0xf38f59d7` (primary)
- secondary selector `0x4300081f`

Reconstructed surface (see [BatchCall.sol](sources/batchcall/BatchCall.sol)):

```solidity
/// @notice Permissionless multi-call. No access control.
function batch(address[] calldata targets, bytes[] calldata datas) external {
    // ← no owner / role / allowlist check on msg.sender
    if (targets.length != datas.length) revert LengthMismatch();
    for (uint256 i = 0; i < targets.length; i++) {
        (bool ok, ) = targets[i].call(datas[i]);
        if (!ok) revert CallFailed(i, targets[i], datas[i]);
    }
}
```

**Missing auth line** is the entire point: there is no `require(msg.sender == …)`
(or equivalent) anywhere in the entrypoint. The contract is a public multicall
proxy that the 7702 BatchExecutor treats as a trusted `BATCHER`.

---

## Attack flow

```text
Attacker EOA (nonce 0)
  └─ CREATE attack contract 0xf210…  (constructor = full exploit)
       ├─ CREATE intermediate 0x5a81… (nonce 1)
       ├─ Drive permissionless BatchCall under 7702 admin authority
       ├─ RESERVE executes QNT.transfer(intermediate, 1988.5465e18)
       ├─ Intermediate multi-hop swaps QNT → WETH / other → ETH
       └─ ETH paid out to attacker EOA (~54.93 ETH)
```

On-chain evidence (attack tx logs):

1. Custom execute event from RESERVE encoding `transfer(0x5a81…, 1988.5465e18)`.
2. QNT `Transfer(RESERVE → intermediate, 1988546547972979064297)`.
3. Subsequent DEX swaps (Balancer, Uniswap-style pools, Permit2, Bancor, …).
4. Attacker EOA ETH balance jumps from ~0.0128 ETH to ~54.95 ETH.

---

## PoC strategy

Same pattern as `2026-05-ONTR_exp`: **replay historical CREATE initcode** at
`FORK_BLOCK = ATTACK_BLOCK - 1`.

```solidity
vm.startPrank(ATTACKER, ATTACKER);
bytes memory initcode = CREATE_INITCODE; // full tx input
address deployed;
assembly {
    deployed := create(0, add(initcode, 0x20), mload(initcode))
}
require(deployed == ATTACK_CONTRACT);
```

Assertions:

- `RESERVE` QNT balance drops by exactly `1988546547972979064297`.
- Admin still has 23-byte `ef0100` designator pre-attack (restored via `vm.etch`
  if the anvil dump stripped it — see caveats).
- Attacker EOA ETH increases (swap residual).

---

## Offline reproduction

```bash
# from registry root
_shared/run_poc.sh 2026-04-QNT_EIP7702_BatchCall_exp -vvv
# expect: [PASS] testExploit
```

`anvil_state.json` is a foundry-cache → anvil conversion of mainnet state at
block `24978302`, with admin 7702 designator code **manually restored** (cache
exports often store `code: 0x` for designator accounts).

---

## Remediation

1. **Never** make a batch/multicall executor callable by the world if it is also
   a trusted `BATCHER` / module of a privileged 7702-delegated identity.
2. Gate `batch()` with a firm allowlist / owner / EIP-712 session key; default
   deny.
3. Prefer EIP-7702 delegates that **reject** unauthenticated outer callers and
   only accept signed user-ops / owner-initiated sessions.
4. Keep high-value reserve assets behind multi-sig / timelock that cannot be
   reached by a single open multicall hop.
5. Monitor 7702 designator changes on treasury / admin EOAs.

---

## 7702 / anvil caveats

| Issue | Mitigation used here |
|-------|----------------------|
| Foundry RPC cache stores empty `code` for `ef0100` designators | Patch `anvil_state.json` accounts[admin].code + `vm.etch` fallback in `setUp` |
| Offline anvil must run with Prague (or later) for 7702 semantics | `foundry.toml` `evm_version = 'prague'` |
| Playground scoring: constructor-only CREATE runs before attack sampling | Synthetic `attack()` re-CREATEs initcode during the recorded attack phase and forwards ETH to the attacker EOA |

---

## References

- Attack tx: https://etherscan.io/tx/0x4f31f68df9f240492f13df9ab23207ea231ec1b5a89af9c31cde58e7d98cb18c
- SlowMist alert: https://x.com/SlowMist_Team/status/2049333031371210854
- EIP-7702: https://eips.ethereum.org/EIPS/eip-7702
