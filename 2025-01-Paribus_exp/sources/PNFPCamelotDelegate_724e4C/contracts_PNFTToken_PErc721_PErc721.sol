// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "../PNFTToken.sol";
import "../../Interfaces/NFTXInterfaces.sol";
import "../../Interfaces/SudoswapInterfaces.sol";
import "openzeppelin2/token/ERC721/IERC721.sol";

/**
 * @title Paribus PErc721 Contract
 * @notice PNFTTokens which wrap an EIP-721 underlying
 * @author Paribus
 */
contract PErc721 is PNFTToken, PErc721Interface {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param name_ ERC-721 name of this token
     * @param symbol_ ERC-721 symbol of this token
     */
    function initialize(address underlying_,
        address comptroller_,
        string memory name_,
        string memory symbol_) public {
        // Sanity check underlying
        require(IERC721(underlying_).balanceOf(address(this)) >= 0, "invalid argument");

        // PToken initialize does the bulk of the work
        super.initialize(underlying_, comptroller_, name_, symbol_);
    }

    function onERC721Received(address, address, uint256, bytes memory) public returns (bytes4) {
        assert(msg.sender == underlying);
        return this.onERC721Received.selector;
    }

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint) {
        return IERC721(underlying).balanceOf(address(this));
    }

    function approveUnderlying(uint tokenId, address addr) internal {
        IERC721(underlying).approve(address(addr), tokenId);
    }

    function checkIfOwnsUnderlying(uint tokenId) internal view returns (bool) {
        return IERC721(underlying).ownerOf(tokenId) == address(this);
    }

    function doTransferIn(address from, uint tokenId) internal { // underlying transfer in
        IERC721(underlying).safeTransferFrom(from, address(this), tokenId);
        assert(checkIfOwnsUnderlying(tokenId));
    }

    function doTransferOut(address to, uint tokenId) internal { // underlying transfer out
        IERC721 token = IERC721(underlying);
        token.safeTransferFrom(address(this), to, tokenId);
        assert(token.ownerOf(tokenId) == to);
    }
}
