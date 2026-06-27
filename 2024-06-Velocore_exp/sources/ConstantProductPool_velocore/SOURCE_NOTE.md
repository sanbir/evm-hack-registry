# Source provenance

The vulnerable contracts `ConstantProductPool.sol`, `ConstantProductLibrary.sol` and the
base `Pool.sol` were NOT verified on Lineascan for the deployed pool
`0xe2c67A9B15e9E7FF8A9Cb0dFb8feE5609923E5DB` (Etherscan V2 returns UNVERIFIED).

They were obtained from the open-source Velocore V2 contracts repository
(GitHub: `Bakasaneqzgh/velocore-contracts`, path `src/pools/constant-product/`), which is the
codebase that was audited/deployed. The on-chain trace (storage slot 6 evolution, the
`feeMultiplier` packing, the `0x72656164`="read" staticcalls to the Vault, and the
`velocore__execute` ABI) all match this source exactly, so it is the correct implementation.

`SwapFacet.sol` and the Vault libraries under `../SwapFacet_2E98EF/` ARE Etherscan-verified
(deployed SwapFacet implementation `0x2E98EF87F7F0d31987A0d94051b8Bc5D001152E8`).
