# Source retrieval notes — Kame AggregationRouter

**Chain:** Sei (pacific-1, chainid 1329). Sei has **no Etherscan V2 API**, and the
seitrace.com explorer (Blockscout) returned persistent HTTP 522 (Cloudflare gateway
down) at audit time, so verified Solidity source could not be downloaded with
`fetch_sources.sh`. Verified source is reported to exist on-chain:
https://seitrace.com/address/0x14bb98581Ac1F1a43fD148db7d7D793308Dc4d80?tab=contract

Instead, the runtime bytecode was fetched from the public Sei RPC
(`eth_getCode` @ latest — bytecode is immutable so available even though historical
*state* at the fork block is pruned) and analyzed directly. This is the
source-of-truth evidence used in the analysis.

## Public function selectors (from on-chain dispatcher)

| Selector | Signature | Notes |
|----------|-----------|-------|
| 0xc4b87069 | `swap((address,address,uint256,address,bytes,bytes))` | **vulnerable** — matches PoC ABI exactly |
| 0x6ccae054 | `rescueFunds(address,address,uint256)` | owner-only fund rescue |
| 0x715018a6 | `renounceOwnership()` | OZ Ownable |
| 0x8da5cb5b | `owner()` | OZ Ownable |
| 0xf2fde38b | `transferOwnership(address)` | OZ Ownable |

Custom errors present: `InvalidMsgValue()` (0x1841b4e1), `ETHTransferFailed()`
(0xb12d13eb), `SafeERC20FailedOperation(address)` (0x5274afe7),
`OwnableUnauthorizedAccount(address)`, `OwnableInvalidOwner(address)`.

## Disassembly of the vulnerable external call (the bug)

The `swap` handler (dispatcher jumps to pc 0x00be=190) loads the executor and
executeParams from calldata and performs an **unchecked low-level CALL** with NO
validation of the target:

```
527: CALLVALUE                 ; msg.value
535: <load params.executor>    ; attacker-controlled target
566: GAS
567: CALL                      ; params.executor.call{value: msg.value}(params.executeParams)
572: RETURNDATASIZE ...        ; capture returnData
```

This corresponds to the line confirmed by the official post-mortem:

```solidity
(bool success, bytes memory returnData) =
    params.executor.call{value: msg.value}(params.executeParams);
```

Sources:
- Kame post-mortem: https://kameagg.substack.com/p/post-mortem-kame-aggregator-exploit
- Quadriga Initiative case study: https://quadrigainitiative.com/casestudy/kameaggregatorswapfunctionarbitraryexecutorcallbug.php
