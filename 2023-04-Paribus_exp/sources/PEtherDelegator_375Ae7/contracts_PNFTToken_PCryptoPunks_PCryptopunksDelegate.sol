// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PCryptoPunks.sol";

/**
 * @title Paribus PCryptopunksDelegate Contract
 * @notice PCryptoPunksDelegate which wrap the CryptoPunks underlying and are delegated to
 * @author Paribus
 */
contract PCryptoPunksDelegate is PCryptoPunks, PNFTTokenDelegateInterface {
    /// @notice Construct an empty delegate
    constructor() public { }

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty. Should not be marked as pure
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes calldata data) external {
        data; // Shh -- currently unused
        require(msg.sender == admin, "only the admin may call _becomeImplementation");
    }

    /// @notice Called by the delegator on a delegate to forfeit its responsibility. Should not be marked as pure
    function _resignImplementation() external {
        require(msg.sender == admin, "only the admin may call _resignImplementation");
    }
}
