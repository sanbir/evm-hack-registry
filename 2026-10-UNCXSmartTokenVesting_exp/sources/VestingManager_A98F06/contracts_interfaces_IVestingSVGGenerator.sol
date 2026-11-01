// SPDX-License-Identifier: UNLICENSED
// ALL RIGHTS RESERVED
// UNCX by SDDTech reserves all rights on this code. You may not copy these contracts.

pragma solidity ^0.8.27;

/// @title IVestingSVGGenerator
/// @notice Interface for the VestingSVGGenerator contract
interface IVestingSVGGenerator {
    /// @notice Generates the complete SVG for a vesting NFT
    /// @param vestingId The vesting ID
    /// @param tokenSymbol The token symbol
    /// @param tokenName The token name
    /// @param totalAmount The total amount to be vested
    /// @param vestedAmount The amount currently vested and available to claim
    /// @param startTime The vesting start time
    /// @param endTime The vesting end time
    /// @param isSoft Whether the vesting is soft
    /// @param isTopable Whether the vesting can be topped up
    /// @param beneficiary The beneficiary address
    /// @param tokenDecimals The token decimals
    /// @return The generated SVG string
    function generateVestingSVG(
        uint256 vestingId,
        string memory tokenSymbol,
        string memory tokenName,
        uint256 totalAmount,
        uint256 vestedAmount,
        uint256 startTime,
        uint256 endTime,
        bool isSoft,
        bool isTopable,
        address beneficiary,
        uint8 tokenDecimals
    ) external view returns (string memory);

    /// @notice Generates the complete token URI for a vesting NFT
    /// @param vestingId The vesting ID
    /// @param tokenSymbol The token symbol
    /// @param tokenName The token name
    /// @param totalAmount The total amount to be vested
    /// @param vestedAmount The amount currently vested and available to claim
    /// @param startTime The vesting start time
    /// @param endTime The vesting end time
    /// @param isSoft Whether the vesting is soft
    /// @param isTopable Whether the vesting can be topped up
    /// @param beneficiary The beneficiary address
    /// @param tokenDecimals The token decimals
    /// @return The generated token URI string
    function generateTokenURI(
        uint256 vestingId,
        string memory tokenSymbol,
        string memory tokenName,
        uint256 totalAmount,
        uint256 vestedAmount,
        uint256 startTime,
        uint256 endTime,
        bool isSoft,
        bool isTopable,
        address beneficiary,
        uint8 tokenDecimals
    ) external view returns (string memory);
} 