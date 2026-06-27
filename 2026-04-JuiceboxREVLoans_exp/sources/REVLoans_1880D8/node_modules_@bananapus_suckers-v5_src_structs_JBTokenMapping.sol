// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member localToken The local token address.
/// @custom:member minGas The minimum gas amount to bridge.
/// @custom:member remoteToken The remote token address.
/// @custom:member minBridgeAmount The minimum bridge amount.
struct JBTokenMapping {
    address localToken;
    uint32 minGas;
    address remoteToken;
    uint256 minBridgeAmount;
}
