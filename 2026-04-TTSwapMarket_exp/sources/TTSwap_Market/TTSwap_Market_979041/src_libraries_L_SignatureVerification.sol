// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title Signature Verification Library
/// @notice Provides functions to verify ECDSA signatures.
/// @dev Supports both standard 65-byte signatures (r, s, v) and EIP-2098 compact 64-byte signatures (r, vs).
library L_SignatureVerification {
    /// @notice Thrown when the passed in signature is not a valid length (must be 64 or 65 bytes).
    error InvalidSignatureLength();

    /// @notice Thrown when the recovered signer is the zero address (ecrecover failure).
    error InvalidSignature();

    /// @notice Thrown when the recovered signer does not match the expected claimedSigner.
    error InvalidSigner();

    /// @notice Thrown when the recovered contract signature is incorrect (reserved for EIP-1271 support in future).
    error InvalidContractSignature();

    bytes32 constant UPPER_BIT_MASK = (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

    /// @notice Verifies that a signature was produced by a specific address.
    /// @param signature The signature bytes (64 or 65 bytes).
    /// @param hash The 32-byte hash of the data that was signed.
    /// @param claimedSigner The address expected to have signed the hash.
    /// @dev Reverts if the signature is invalid or the signer does not match.
    function verify(bytes calldata signature, bytes32 hash, address claimedSigner) internal pure {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length == 65) {
            (r, s) = abi.decode(signature, (bytes32, bytes32));
            v = uint8(signature[64]);
        } else if (signature.length == 64) {
            // EIP-2098
            bytes32 vs;
            (r, vs) = abi.decode(signature, (bytes32, bytes32));
            s = vs & UPPER_BIT_MASK;
            v = uint8(uint256(vs >> 255)) + 27;
        } else {
            revert InvalidSignatureLength();
        }
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        if (signer != claimedSigner) revert InvalidSigner();
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)
    revert InvalidSignature();
    }
}
