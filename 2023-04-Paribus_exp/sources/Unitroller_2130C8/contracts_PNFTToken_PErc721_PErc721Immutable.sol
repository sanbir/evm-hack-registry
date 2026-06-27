// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PErc721.sol";

/**
 * @title Paribus PErc721Immutable Contract
 * @notice PErc721Tokens which wrap an EIP-721 underlying and are immutable
 * @author Paribus
 */
contract PErc721Immutable is PErc721 {
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param name_ ERC-721 name of this token
     * @param symbol_ ERC-721 symbol of this token
     * @param admin_ Address of the administrator of this token
     */
    constructor(address underlying_,
                address comptroller_,
                string memory name_,
                string memory symbol_,
                address payable admin_) public {
        // Creator of the contract is admin during initialization
        admin = msg.sender;

        // Initialize the market
        initialize(underlying_, comptroller_, name_, symbol_);

        // Set the proper admin now that initialization is done
        admin = admin_;
    }
}
