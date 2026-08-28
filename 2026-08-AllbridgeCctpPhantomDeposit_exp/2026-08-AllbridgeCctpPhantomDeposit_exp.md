# Allbridge CCTP — Phantom Deposit on Base (~$191K)

<!-- non-defihacklabs: Crypto Training original detection & analysis (Twitter hack alerting) -->
<!-- date: 2026-08 -->

> **Vulnerability classes:** vuln/bridge/message-validation · vuln/bridge/false-deposit · vuln/defi/flash-loan

> **Reproduction:** Foundry fork replay at Base block **50157344** (one before the drain). Historical harness calldata redeems a Circle-attested generic `sendMessage` that minted **0 USDC**, books a phantom 1M credit in `CCTPTokenMessenger.receivedMessages`, flash-loans the shortfall from Aave V3, and drains the router via `Router.receiveToken`. Offline `anvil_state.json` + `_shared/run_poc.sh` **[PASS]**. Basis: [Defimon](https://defimon.xyz/blog/allbridge-hack-august-2026) · [DefimonAlerts](https://x.com/DefimonAlerts/status/2090369928494719263).

---

## Key info

| | |
|---|---|
| **Loss** | **~$191,156 USDC** (router emptied). Attacker net **~189,751.55 USDC** after 10 bp fee + Aave premium |
| **Chain** | Base (chainId **8453**) |
| **Protocol** | Allbridge Next — CCTP router path (no liquidity pool) |
| **Date** | 2026-08-19 |
| **Attacker EOA** | [`0x2419432344b0B892E592b2601B98eaE702Ba360e`](https://basescan.org/address/0x2419432344b0b892e592b2601b98eae702ba360e) |
| **Exploit harness** | [`0xb6fBDFA5F3CBEB139D4ccE86D92F4ac8687B16c0`](https://basescan.org/address/0xb6fbdfa5f3cbeb139d4cce86d92f4ac8687b16c0) |
| **Logic (initcode)** | [`0xe9edf1582ed9520f7149669d9c6bf3276b02477e`](https://basescan.org/address/0xe9edf1582ed9520f7149669d9c6bf3276b02477e) (created in the attack tx) |
| **Victim Router** | [`0xaA119F7442eCC28b9a8F236707ADA8362CFF24fF`](https://basescan.org/address/0xaa119f7442ecc28b9a8f236707ada8362cff24ff) |
| **Vulnerable messenger** | [`0xf9B710E427bf4D93598E0F80A84de22C7Ad9B577`](https://basescan.org/address/0xf9b710e427bf4d93598e0f80a84de22c7ad9b577) — `CCTPTokenMessenger` |
| **USDC (Base)** | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fcd6edb6e08f4c7c32d4f71b54bda02913) |
| **Flash lender** | Aave V3 Pool [`0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`](https://basescan.org/address/0xa238dd80c259a72e81d7e4664a9801593f98d1c5) |
| **Attack tx** | [`0x9f906fcd…e6a8`](https://basescan.org/tx/0x9f906fcd8fceaa6745e8d1c004861dcfa9b5e6a893fe1e8c5d0013a4e982e6a8) @ block **50157345** |
| **Forged sendMessage** | Polygon [`0x2a88d797…2140`](https://polygonscan.com/tx/0x2a88d79756b4547b33fea7b3c1420793680e2b8952bef4c65e99879e16b22140) (2026-07-25) |
| **Alerts / analysis** | [DefimonAlerts](https://x.com/DefimonAlerts/status/2090369928494719263) · [Defimon writeup](https://defimon.xyz/blog/allbridge-hack-august-2026) |
| **Bug class** | **Bridge message validation / false deposit** — `receiveCctpMessage` credits `amount - feeExecuted` from an attested CCTP body into `receivedMessages[hookDataHash]` **without** checking that USDC was minted or that balances increased |

---

## TL;DR

Allbridge’s new CCTP router on Base treated a Circle-attested **generic** `MessageTransmitterV2.sendMessage` as a real USDC deposit. The attacker authored a burn-shaped body declaring **1,000,000 USDC**, pointed `recipient` at their own harness (so Circle’s TokenMessenger never minted), and set `destinationCaller` to Allbridge’s messenger. Circle attested it on Polygon on **July 25**; **24 days later**, six seconds after a legitimate ~191k USDC inflow landed in the router, the attacker redeemed the phantom credit, flash-loaned the shortfall from Aave, called `Router.receiveToken`, and walked with **~189.75k USDC**.

Root cause is a single missing check in `CCTPTokenMessenger.receiveCctpMessage`:

```solidity
receivedMessages[messageHash] = receivedAmount; // no balance / mint check
```

---


## Secondary analysis (@SlowMist_Team)

> Bridge message validation / phantom CCTP deposit: receiveCctpMessage credits attacker-authored amount+messageHash without requiring sender=remote TokenMessenger, recipient=Circle TokenMessengerV2, or an observed USDC mint/balance increase

Source: https://x.com/SlowMist_Team/status/2090994186346790999


## The vulnerable code (verbatim)

### 1. Phantom credit after Circle `receiveMessage` (signature / message-validation bug)

`sources/CCTPTokenMessenger/CCTPTokenMessenger.sol` — **line 182**:

```solidity
function receiveCctpMessage(bytes calldata message, bytes calldata attestation) external {
    require(message.length >= 408, "Message too short");
    uint32 sourceDomain = uint32(bytes4(message[4:8]));
    bytes32 destCaller  = bytes32(message[108:140]);
    uint256 amount      = uint256(bytes32(message[216:248]));   // attacker-authored
    uint256 feeExecuted = uint256(bytes32(message[312:344]));
    bytes32 sourceSender = bytes32(message[248:280]);           // attacker-authored
    bytes32 messageHash  = bytes32(message[376:408]);           // attacker-authored hookData

    require(destCaller == bytes32(uint256(uint160(address(this)))), "Invalid destination caller");
    uint32 sourceChainId = domainToChainId[sourceDomain];
    require(sourceChainId != 0, "Unknown source domain");
    require(sourceSender == remoteTokenMessengers[sourceChainId], "Invalid remote sender");

    bool success = IMessageTransmitter(MESSAGE_TRANSMITTER).receiveMessage(message, attestation);
    require(success, "CCTP receiveMessage failed");

    uint256 receivedAmount = amount - feeExecuted;
    receivedMessages[messageHash] = receivedAmount; // @audit PHANTOM CREDIT — no USDC mint/balance check
    emit MessageReceived(messageHash);
}
```

Circle correctly asserts the message is authentic. It does **not** assert that a burn/mint occurred. Generic `sendMessage` attests arbitrary payloads with **zero** USDC movement. The `sourceSender == remoteTokenMessengers[...]` check is attacker-satisfiable: the body field is copied from the publicly readable mapping.

### 2. Router pays on the phantom credit

`sources/Router/Router.sol` — `receiveToken` only requires a nonzero messenger credit for the caller-supplied hash tuple:

```solidity
bytes32 messageHash =
    _calculateMessageHash(_nonce, recipient, destinationToken, normalizedAmount, sourceChain, CHAIN_ID);
require(!usedMessages[messageHash], "Message already used");
uint256 receivedAmount = ITokenMessenger(tokenMessengersAddr).receivedTokenAmount(messageHash);
require(receivedAmount > 0, "Message not received"); // solvency == accounting entry
// ... fee, then IERC20(intermediaryToken).safeTransfer(recipientAddr, amountAfterFee);
```

The hash `(nonce=12345, recipient=harness, USDC, normalizedAmount=1e15, sourceChain=12345, CHAIN_ID=9)` equals `0xe15a0288…c52e`, which was embedded as `hookData` in the forged body months earlier.

---

## Attack flow

1. **Jul 25 (Polygon):** `MessageTransmitterV2.sendMessage` with burn-shaped body, `amount=1e12`, `recipient=harness`, `destinationCaller=Allbridge messenger`, `messageSender=remoteTokenMessengers[5]`. No burn. Circle attests.
2. **Aug 19 01:47:11 UTC (Base 50157342):** Legitimate CCTP mint credits the router with ~191,112 USDC (total ~191,156).
3. **01:47:17 (50157345):** Attacker calls harness with initcode that:
   - constructor → `receiveCctpMessage(message, attestation)` (phantom 1M credit, 0 mint);
   - `flashLoanSimple` shortfall (~808,844 USDC) from Aave;
   - tops router to 1M;
   - `Router.receiveToken(1e15, 12345, 12345, USDC, harness, …)` → **999,000 USDC** out;
   - repays Aave (+ premium).
4. Net on harness: **189,751.554381 USDC**. Router left with the 1,000 USDC fee accrual (later skimmed by a copycat).

---

## PoC

```text
cd audits/evm-hack-registry
bash _shared/run_poc.sh 2026-08-AllbridgeCctpPhantomDeposit_exp -vv
```

| Test | What it shows |
|------|----------------|
| `testExploit` | Exact historical harness calldata replay |
| `testPhantomCredit_noMint` | Credit booked, messenger/router USDC unchanged |
| `testStepByStepFlashLoanDrain` | Explicit Aave flash-loan + pranked `receiveToken` |

Asserted profit band: **189k–191.156k USDC**. Observed: **189751.554381 USDC**.

---

## Fix direction

Credit must be conditional on an **observed** balance increase across `receiveMessage` (or require `message.recipient` to be Circle’s `TokenMessengerV2`). Unregistering messengers (Allbridge’s containment) closes payouts but does not patch `receiveCctpMessage`.

---

## References

- https://x.com/SlowMist_Team/status/2090994186346790999 (@SlowMist_Team secondary analysis)

- https://defimon.xyz/blog/allbridge-hack-august-2026
- https://x.com/DefimonAlerts/status/2090369928494719263
- https://basescan.org/tx/0x9f906fcd8fceaa6745e8d1c004861dcfa9b5e6a893fe1e8c5d0013a4e982e6a8
- https://polygonscan.com/tx/0x2a88d79756b4547b33fea7b3c1420793680e2b8952bef4c65e99879e16b22140
