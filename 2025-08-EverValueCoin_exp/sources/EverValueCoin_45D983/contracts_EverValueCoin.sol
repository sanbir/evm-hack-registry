// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title EverValueCoin (EVA)
/// @notice EverValueCoin (EVA) is a burnable ERC20 token with a limited supply, designed to work on the Arbitrum network.
/// @dev This contract manages the minting and burning of EVA tokens. The total supply is capped at 21,000,000 tokens.
contract EverValueCoin is ERC20 {
    /// @notice The name of the token to be created upon deployment
    string private constant nameForDeploy = "EverValueCoin";
    /// @notice The symbol of the token to be created upon deployment
    string private constant symbolForDeploy = "EVA";
    /// @notice The maximum number of EVA tokens that can ever exist
    uint256 public constant MAX_SUPPLY = 21_000_000 * 10 ** 18;

    /// @notice Constructor that mints the entire supply to the deployer and sets the name and symbol of the token
    constructor() ERC20(nameForDeploy, symbolForDeploy) {
        _mint(msg.sender, MAX_SUPPLY);
    }

    /// @notice Burns a specified amount of the caller's EVA tokens
    /// @dev Reduces the caller's balance of EVA tokens
    /// @param amount The number of EVA tokens to burn
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /// @notice Burns a specified amount of tokens from a specific account
    /// @dev Reduces the balance of the specified account, spending the caller's allowance
    /// @param account The address of the account to burn tokens from
    /// @param amount The number of EVA tokens to burn
    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }
}
