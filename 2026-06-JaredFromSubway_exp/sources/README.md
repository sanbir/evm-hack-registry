# Sources notes — JaredFromSubway residual-approval drain

## Verified on-chain
- `WETH9_C02aaA/` — canonical WETH9 at `0xC02a…Cc2` (drain asset; `transferFrom` moves funds under residual allowance).
- `FiatTokenProxy_A0b869/` — USDC proxy (second drain asset). Implementation is separate; playground may use bytecode for deep frames.

## Unverified (bytecode only)
- Victim MEV bot `0x1f2F10D1C40777AE1Da742455c65828FF36Df387` — sandwich/arb bot that left residual ERC-20 approvals to bait wrappers.
- Coordinator `0xb84db016324e8F2BFdD8DD9c260338AEE0A8DF52` — final sweep loops 66 child contracts; selector `0xc269a509`.
- 66 bait child/wrapper contracts — received real-token allowances during baited "arbitrage" hops; large baits skipped `transferFrom` of real tokens.

## Root cause (bot approval hygiene)
Not a classical protocol logic bug inside a verified public app. The bot granted real WETH/USDC/USDT allowances to untrusted wrappers during sandwich paths, did not verify consumption, and did not revoke residual allowance. The honeypot bait layer staged small profitable-looking hops so residual max approvals accumulated; one coordinator call drained them.
