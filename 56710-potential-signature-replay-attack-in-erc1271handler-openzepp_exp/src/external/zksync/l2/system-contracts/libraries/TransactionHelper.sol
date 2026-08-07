// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ---------------------------------------------------------------------------
// ISOLATION BOUNDARY (not the vulnerable contract).
// The audited `IModuleValidator` interface references the zkSync-native
// `Transaction` struct type only to declare `validateTransaction(bytes32,
// Transaction)`. That branch of `isValidSignature` is NOT on the reproduced
// exploit path (the finding's EOA/1271 replay uses the 65-byte ECDSA branch).
// The full `@matterlabs/zksync-contracts` TransactionHelper pulls in the entire
// zkSync system-contract closure (SystemContractsCaller / EfficientCall /
// bootloader), which cannot run on a vanilla EVM. Per the SKILL's isolation
// guidance we vendor ONLY the real, byte-identical `Transaction` struct so the
// interface type-checks. The vulnerable `ERC1271Handler.isValidSignature` and
// the real `OwnerManager` owner set are untouched real audited source.
// Struct copied verbatim from @matterlabs/zksync-contracts@0.6.1
//   l2/system-contracts/libraries/TransactionHelper.sol
// ---------------------------------------------------------------------------

uint8 constant EIP_712_TX_TYPE = 0x71;
uint8 constant LEGACY_TX_TYPE = 0x0;
uint8 constant EIP_2930_TX_TYPE = 0x01;
uint8 constant EIP_1559_TX_TYPE = 0x02;

/// @notice Structure used to represent zkSync transaction.
struct Transaction {
    uint256 txType;
    uint256 from;
    uint256 to;
    uint256 gasLimit;
    uint256 gasPerPubdataByteLimit;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 paymaster;
    uint256 nonce;
    uint256 value;
    uint256[4] reserved;
    bytes data;
    bytes signature;
    bytes32[] factoryDeps;
    bytes paymasterInput;
    bytes reservedDynamic;
}
