// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PErc721.sol";

/**
 * @title Paribus PErc721Delegate Contract
 * @notice PErc721Tokens which wrap an EIP-721 underlying and are delegated to
 * @author Paribus
 */
contract PErc721Delegate is PErc721, PNFTTokenDelegateInterface {
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
