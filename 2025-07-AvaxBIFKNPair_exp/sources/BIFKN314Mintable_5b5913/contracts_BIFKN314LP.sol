// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./BIFKNERC20.sol";

/**
 * @title BIFKN314LP
 * @dev Implementation of the liquidity provider (LP) token for the BIFKN314 AMM pool.
 */
contract BIFKN314LP is BIFKNERC20 {
    /**
     * @dev The address of the Automated Market Maker (AMM) contract.
     */
    address public immutable ammAddress;

    error Unauthorized(address sender);

    /**
     * @dev Modifier that allows only the owner (amm) to call the function.
     * If the caller is not the owner, it will revert with an `OnlyOwnerError` error.
     */
    modifier onlyOwner() {
        if (_msgSender() != ammAddress) revert Unauthorized(_msgSender());
        _;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor() BIFKNERC20() {
        ammAddress = _msgSender();
    }

    /**
     * @dev Initializes the contract with the given name and symbol.
     *
     * This function is called by the contract owner to initialize the contract.
     * It sets the name and symbol of the contract by calling the `initialize` function
     * of the parent contract.
     *
     * @param tokenName The name of the contract.
     * @param tokenSymbol The symbol of the contract.
     */
    function initialize(
        string memory tokenName,
        string memory tokenSymbol
    ) public override onlyOwner {
        super.initialize(tokenName, tokenSymbol);
    }

    /**
     * @dev Function to mint tokens
     *
     * Requirements:
     * - the caller must be the BIFKN314 contract.
     *
     * @param account The address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address account, uint256 amount) public onlyOwner {
        super._mint(account, amount);
    }
}
