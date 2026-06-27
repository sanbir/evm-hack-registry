// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title HashrateRegistry
/// @notice Breaks the WHALE ↔ WHALEHashrate ↔ Vaults circular dependency by holding the six
///         predicted contract addresses. Deployed via regular `CREATE` (address depends only
///         on `(deployer, nonce)`, NOT on constructor args), so the registry's address can be
///         baked into the other six contracts' init-code-hashes deterministically.
///
///         Deploy order (single broadcast script):
///           1. Predict all six addresses off-chain (CREATE2 for hashrate / WHALE / vaults,
///              CREATE for registry).
///           2. Deploy registry with the six predicted addresses as constructor args.
///           3. Deploy WHALEHashrate via CREATE2 (constructor reads `registry.whale()`).
///           4. Deploy WHALE via CREATE2 (constructor reads `registry.hashrate()`, vault addrs).
///           5. Deploy 4 vaults via CREATE2 (each constructor reads its `whale` / `hashrate`).
///           6. Sanity-assert every actual address matches its prediction (else revert tx).
///
///         Holds 8 v9.x contract addresses (WHALE, hashrate, pair, 4 vaults, zapRouter).
contract HashrateRegistry {
    address public immutable whale;
    address public immutable hashrate;
    address public immutable pair;       // PancakeSwap WHALE/USDT pair (Round-2 fix I-1: WHALEHashrate filter)
    address public immutable burnVault;
    address public immutable refVault;
    address public immutable polVault;
    address public immutable fomoVault;
    /// @notice v9.x zap helper that lets users do USDT-only one-click LP. WHALE
    ///      grants buy-tax exemption to this address and redirects Method-B
    ///      credit through `IWhaleZapRouter.pendingUser()` during settle.
    address public immutable zapRouter;

    error ZeroAddress();

    constructor(
        address _whale,
        address _hashrate,
        address _pair,
        address _burnVault,
        address _refVault,
        address _polVault,
        address _fomoVault,
        address _zapRouter
    ) {
        if (
            _whale == address(0) || _hashrate == address(0) || _pair == address(0)
                || _burnVault == address(0) || _refVault == address(0) || _polVault == address(0)
                || _fomoVault == address(0)
        ) revert ZeroAddress();
        // _zapRouter MAY be zero — it's an optional v9.x helper. See WHALE.sol
        // constructor comment for the security analysis (gate conditions
        // `to == WHALE_ZAP_ROUTER` / `creditUser == WHALE_ZAP_ROUTER` can never
        // match address(0) in any practical flow, so zero is structurally safe).

        whale = _whale;
        hashrate = _hashrate;
        pair = _pair;
        burnVault = _burnVault;
        refVault = _refVault;
        polVault = _polVault;
        fomoVault = _fomoVault;
        zapRouter = _zapRouter;
    }
}
