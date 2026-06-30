// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BIFKN314.sol";

contract BIFKN314Mintable is BIFKN314 {
    address public minter;
    uint256 public mintCap;
    bool public mintingEnabled;

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    error MinterAlreadySet();
    error NotMinter();
    error MintCapExceeded();
    error MintingDisabled();
    error InvalidOperation();

    constructor() BIFKN314() {}

    /**
     * @dev Initializes the BIFKN314Mintable contract with standard parameters plus minting parameters.
     * @param factoryAddress The address of the factory contract.
     * @param tokenName The name of the token.
     * @param tokenSymbol The symbol of the token.
     * @param initialSupply The initial supply to mint.
     * @param maxSupply The maximum supply that can be minted (0 for unlimited).
     * @param minterAddress The address that will have minting rights.
     * @param feeRate_ The trading fee rate.
     * @param maxWalletPercent_ The maximum wallet percentage.
     * @param metadataURI_ The URI for the token metadata.
     */
    function initializeMintable(
        address factoryAddress,
        string memory tokenName,
        string memory tokenSymbol,
        uint256 initialSupply,
        uint256 maxSupply,
        address minterAddress,
        uint256 feeRate_,
        uint256 maxWalletPercent_,
        string memory metadataURI_
    ) external onlyOwner {
        // Initialize base contract
        if (address(factory) != address(0)) revert AlreadyInitialized();
        factory = IBIFKN314FactoryV2(factoryAddress);

        super.initialize(tokenName, tokenSymbol);

        // Set minting parameters
        if (minterAddress == address(0)) revert InvalidAddress();
        minter = minterAddress;
        mintCap = maxSupply;
        mintingEnabled = true;

        // Set token parameters
        if (maxWalletPercent_ > 0) {
            maxWalletEnabled = true;
            setMaxWalletPercent(maxWalletPercent_);
        }

        setTradingFeeRate(feeRate_);
        metadataURI = metadataURI_;
        feeCollector = owner; // Set fee collector to the contract owner

        // Mint initial supply to owner
        if (initialSupply > 0) {
            if (maxSupply > 0 && initialSupply > maxSupply)
                revert MintCapExceeded();
            super._mint(msg.sender, initialSupply);
        }
    }

    /**
     * @dev Initializes the contract with the given token name and symbol.
     * This function is overridden to prevent direct initialization by reverting
     * with an `InvalidOperation` error. Only the owner can call this function.
     *
     * Requirements:
     *
     * - This function can only be called by the owner.
     * - Direct initialization is not allowed and will revert.
     */
    function initialize(
        string memory,
        string memory
    ) public view override onlyOwner {
        revert InvalidOperation(); // Prevent direct initialization
    }

    /**
     * @dev Initializes the factory contract with a factory.
     * @notice This function can only be called once to initialize the factory contract.
     * @notice If the factory contract has already been initialized, calling this function will revert.
     *
     * @notice This function is overridden to prevent direct initialization by reverting
     * with an `InvalidOperation` error. Only the owner can call this function.
     */
    function initializeFactory(address) public view override onlyOwner {
        revert InvalidOperation(); // Block direct factory initialization
    }

    /**
     * @dev Sets the total supply, owner, fee rate, max wallet percentage, and metadata URI for the token.
     * This function is overridden and not applicable for mintable tokens, as indicated by the `InvalidOperation` revert.
     *
     * @notice This function will always revert with `InvalidOperation` for mintable tokens.
     */
    function setSupplyAndMint(
        uint256,
        address,
        uint256,
        uint256,
        string memory
    ) public view override onlyOwner {
        revert InvalidOperation(); // This function is not applicable for mintable tokens
    }

    /**
     * @dev Mints new tokens. Can only be called by the minter.
     * @param to The address to receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (!mintingEnabled) revert MintingDisabled();
        if (to == address(0)) revert InvalidAddress();

        // Check mint cap if it's set
        if (mintCap > 0) {
            if (totalSupply() + amount > mintCap) revert MintCapExceeded();
        }

        _mint(to, amount);
    }

    /**
     * @dev Enables or disables minting functionality
     * @param enabled Boolean to enable/disable minting
     */
    function setMintingEnabled(bool enabled) external onlyOwner {
        mintingEnabled = enabled;
    }

    /**
     * @dev Changes the minter address
     * @param newMinter The new minter address
     */
    function changeMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) revert InvalidAddress();
        minter = newMinter;
    }
}
