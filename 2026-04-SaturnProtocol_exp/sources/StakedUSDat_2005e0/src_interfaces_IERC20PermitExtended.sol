// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IERC20PermitExtended
/// @notice Extended permit interface supporting EIP-1271 smart contract wallet signatures
/// @dev Extends IERC20Permit to add support for raw bytes signatures used by smart contract
/// wallets like Gnosis Safe, Argent, and account abstraction wallets.
interface IERC20PermitExtended is IERC20Permit {
    /// @notice Approves `spender` to spend `value` tokens on behalf of `owner` via signature.
    /// @dev This overload accepts raw bytes for EIP-1271 smart contract wallet compatibility.
    /// @param owner The address of the token owner.
    /// @param spender The address of the spender.
    /// @param value The amount of tokens to approve.
    /// @param deadline The timestamp after which the permit is no longer valid.
    /// @param signature The EIP-1271 compatible signature bytes.
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) external;
}
