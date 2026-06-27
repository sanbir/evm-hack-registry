// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PCryptoPunks.sol";

/**
 * @title Paribus PCryptoPunksImmutable Contract
 * @notice PNFTTokens which wrap the CryptoPunks collection underlying and are immutable
 * @author Paribus
 */
contract PCryptoPunksImmutable is PCryptoPunks {
    /**
     * @notice Construct a new money market
     * @param underlying_ The CryptoPunks collection address
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
