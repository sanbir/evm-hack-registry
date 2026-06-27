// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title HashrateRegistry
/// @notice Breaks the LBP ↔ LBPHashrate ↔ Vaults circular dependency by holding the six
///         predicted contract addresses. Deployed via regular `CREATE` (address depends only
///         on `(deployer, nonce)`, NOT on constructor args), so the registry's address can be
///         baked into the other six contracts' init-code-hashes deterministically.
///
///         Deploy order (single broadcast script):
///           1. Predict all six addresses off-chain (CREATE2 for hashrate / LBP / vaults,
///              CREATE for registry).
///           2. Deploy registry with the six predicted addresses as constructor args.
///           3. Deploy LBPHashrate via CREATE2 (constructor reads `registry.lbp()`).
///           4. Deploy LBP via CREATE2 (constructor reads `registry.hashrate()`, vault addrs).
///           5. Deploy 4 vaults via CREATE2 (each constructor reads its `lbp` / `hashrate`).
///           6. Sanity-assert every actual address matches its prediction (else revert tx).
///
///         Holds all 6 v8 contract addresses (LBP, hashrate, pair, 4 vaults).
contract HashrateRegistry {
    address public immutable lbp;
    address public immutable hashrate;
    address public immutable pair;       // PancakeSwap LBP/USDT pair (Round-2 fix I-1: LBPHashrate filter)
    address public immutable burnVault;
    address public immutable refVault;
    address public immutable polVault;
    address public immutable fomoVault;

    error ZeroAddress();

    constructor(
        address _lbp,
        address _hashrate,
        address _pair,
        address _burnVault,
        address _refVault,
        address _polVault,
        address _fomoVault
    ) {
        if (
            _lbp == address(0) || _hashrate == address(0) || _pair == address(0)
                || _burnVault == address(0) || _refVault == address(0) || _polVault == address(0)
                || _fomoVault == address(0)
        ) revert ZeroAddress();

        lbp = _lbp;
        hashrate = _hashrate;
        pair = _pair;
        burnVault = _burnVault;
        refVault = _refVault;
        polVault = _polVault;
        fomoVault = _fomoVault;
    }
}
