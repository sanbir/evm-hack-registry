# Sources

The vulnerable contract `0xD4F1AFD0331255e848c119CA39143D41144f7Cb3` is **UNVERIFIED**
on BscScan (it is the source of the PoC filename suffix `unverified`). Etherscan V2
returns `UNVERIFIED` for chainid 56. No verified Solidity source is available.

The analysis below is reconstructed from:
- The live execution trace (`../output.txt`)
- On-chain bytecode and storage inspection via `cast` (see `bytecode_facts.md`)
- The two ERC-7201 namespaced storage slots written during the attack, which
  uniquely identify OpenZeppelin v5 `Initializable` + `OwnableUpgradeable`.
