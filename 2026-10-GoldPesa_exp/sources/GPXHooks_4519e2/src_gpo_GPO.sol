// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from"openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title GoldPesa Option (GPO)
 * @notice A fully decentralized, immutable, and trustless DeFi contract with no owner.
 * - 1 GPO can be periodically converted into 1 GPX when staked in the GoldPesa Vault.
 */
contract GPO is ERC20, ERC20Permit {
    
    /// @notice Token Name
    string public constant Name = "GoldPesa Option";
    /// @notice Token Symbol
    string public constant Symbol = "GPO";
    /// @notice GPO Hard Cap
    uint256 public constant FixedSupply = 100_000_000;

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @dev Initializes the contract, mints the GPO Hard Cap
     */
    constructor() ERC20(Name, Symbol) ERC20Permit(Name) {
        // Mint total hard cap token supply to deployer address (GPO Hook)
        _mint(msg.sender, FixedSupply * (10**(uint256(decimals()))));
    }
}
