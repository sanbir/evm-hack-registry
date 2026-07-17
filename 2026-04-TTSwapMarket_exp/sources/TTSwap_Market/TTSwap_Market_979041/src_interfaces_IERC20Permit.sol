// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

///
/// @dev Interface for token permits for ERC-721
///
interface IERC20Permit {
    /// ERC165 bytes to add to interface array - set in parent contract
    ///
    /// _INTERFACE_ID_ERC4494 = 0x5604e225

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    /// @notice Returns the nonce of an NFT - useful for creating permits
    /// @param tokenId the index of the NFT to get the nonce of
    /// @return the uint256 representation of the nonce
    function nonces(uint256 tokenId) external view returns (uint256);

    /// @notice Returns the domain separator used in the encoding of the signature for permits, as defined by EIP-712
    /// @return the bytes32 domain separator
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
