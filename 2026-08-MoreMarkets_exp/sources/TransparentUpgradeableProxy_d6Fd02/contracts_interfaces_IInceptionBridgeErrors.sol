// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInceptionBridgeErrors {
    /// @dev
    error ShortCapExceeded(uint256 limit, uint256 current);
    /// @dev
    error LongCapExceeded(uint256 limit, uint256 current);

    /// @dev
    error BridgeAlreadyAdded();
    error BridgeNotExist();

    error InvalidChain();

    error MultipleDeposits();

    /// @dev
    error ReceiptWrongChain(uint256 required, uint256 provided);

    /// @dev
    error InvalidContractAddress();

    error NullAddress();

    /// @dev
    error UnknownBridge();

    /// @dev
    error WrongSignature();

    error WithdrawalProofUsed();

    error InvalidAssetType();

    error InvalidFromTokenAddress();

    error UnknownDestination();

    error WrongDestinationBridge();

    error XERC20LockboxAlreadyAdded();

    error XERC20ZeroAddress();

    /// @notice non-existing-bridge
    error UnknownDestinationChain();

    error DestinationAlreadyExists();

    error BurnFailed();

    error MintFailed();
}
