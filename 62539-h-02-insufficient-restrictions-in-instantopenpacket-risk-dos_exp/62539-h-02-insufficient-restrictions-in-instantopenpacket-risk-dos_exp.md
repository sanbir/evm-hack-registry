# RipIt: Two same-block INSTANT_OPEN_PACKET requests for a packetType with only 1 bundle both pass 

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62539-h-02-insufficient-restrictions-in-instantopenpacket-risk-dos.md -->

## Root cause

Two same-block INSTANT_OPEN_PACKET requests for a packetType with only 1 bundle both pass the request-time check; the first VRF fulfillment pops the bundle and serves user1, but user2's fulfillRandomWords reverts (NoAvailableCardBundles) and, per Chainlink's no-retry-on-revert semantics, user2's packet is permanently stuck/unopenable (1 locked Packet NFT frozen).

```solidity
    function instantOpenPacket(uint256 packetId, uint256 packetType, address owner) external {
        if (msg.sender != packetNFTAddress) revert UnauthorizedCaller();

        if (packetTypeToCardBundles[packetType].length == 0) revert InsufficientCardBundles(); // @> request-time check does NOT reserve/decrement a bundle: two same-block requests both pass while only one bundle exists (TOCTOU DoS)

        // Request randomness from Chainlink VRF
```

## Why it's exploitable here

Two same-block INSTANT_OPEN_PACKET requests for a packetType with only 1 bundle both pass the request-time check; the first VRF fulfillment pops the bundle and serves user1, but user2's fulfillRandomWords reverts (NoAvailableCardBundles) and, per Chainlink's no-retry-on-revert semantics, user2's packet is permanently stuck/unopenable (1 locked Packet NFT frozen).

## Attack path

```mermaid
flowchart TD
  S0["Store packet NFT address"]
  S1["Admin adds a card bundle"]
  S2["Check only bundle count is nonzero"]
  S3["Request VRF randomness"]
  S4["VRF request helper"]
  H["Two same-block INSTANT_OPEN_PACKET requests for a packetType with only"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L121** — Store packet NFT address: Setup: constructor wires the Packet NFT contract address used when packets are opened.
2. **L125** — Admin adds a card bundle: Setup: admin registers a card bundle for a `packetType`; the target type is given only one bundle.
3. **L137** — Check only bundle count is nonzero: Root-cause: request-time check only rejects zero bundles and reserves nothing per in-flight request, so two same-block requests both pass with only 1 bundle.
4. **L140** — Request VRF randomness: Kicks off a Chainlink VRF request for the packet; both same-block requests reach here since neither reserved the lone bundle.
5. **L147** — VRF request helper: Setup: internal helper that submits the VRF randomness request and returns its `requestId`.
6. **L158** — VRF fulfillment callback: The VRF callback that pops a bundle and serves the user; the second user's callback finds no bundle left and reverts.
7. **L169** — Mark request fulfilled: Marks the request done for the served user; the reverting second callback never reaches here, so that packet stays permanently stuck.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62539-h-02-insufficient-restrictions-in-instantopenpacket-risk-dos_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Two same-block INSTANT_OPEN_PACKET requests for a packetType with only 1 bundle both pass the request-time check; the first VRF fulfillment **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
