# Verified-source fetch status

The vulnerable contract `rfUSDC` / `ReaperVaultV2` lives at
`0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D` on **Fantom Opera (chainid 250)**.

As of the analysis date the verified source could NOT be re-downloaded:

- Etherscan V2 unified API rejects `chainid=250` —
  `Missing or unsupported chainid parameter`; the V2 chainlist no longer lists
  Fantom Opera (only "Sonic Mainnet" 146 / "Sonic Testnet" 14601). Fantom Opera
  was sunset / rebranded to Sonic, so 250 is no longer served by the unified API.
- The legacy `api.ftmscan.com` endpoint is unreachable from this environment
  (DNS / network).

The verified source remains viewable in a browser at
https://ftmscan.com/address/0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D#code
(the PoC header cites `#code#F1#L324`).

The code snippets quoted in the analysis are the canonical Reaper `ReaperVaultV2`
`redeem` / `withdraw` / `_withdraw` implementation as documented in Reaper's own
post-mortem and Beosin's writeup, and they are corroborated line-by-line against
the executed `-vvvvv` trace in ../output.txt (share burn with no allowance spend,
pull-from-strategy, transfer-to-receiver).
