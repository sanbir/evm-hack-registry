// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../PNFTToken.sol";
import "../../Interfaces/CryptoPunksMarketInterface.sol";
import "../../Interfaces/NFTXInterfaces.sol";

/**
 * @title Paribus PCryptoPunks Contract
 * @notice PNFTTokens which wrap the CryptoPunks collection underlying
 * @author Paribus
 */
contract PCryptoPunks is PNFTToken {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The CryptoPunks collection address
     * @param comptroller_ The address of the Comptroller
     * @param name_ ERC-721 name of this token
     * @param symbol_ ERC-721 symbol of this token
     */
    function initialize(address underlying_,
        address comptroller_,
        string memory name_,
        string memory symbol_) public {
        // PToken initialize does the bulk of the work
        super.initialize(underlying_, comptroller_, name_, symbol_);

        // Sanity check underlying
        CryptoPunksMarketInterface(underlying).imageHash();
    }

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint) {
        return CryptoPunksMarketInterface(underlying).balanceOf(address(this));
    }

    function approveUnderlying(uint256 tokenId, address addr) internal {
        CryptoPunksMarketInterface(underlying).offerPunkForSaleToAddress(tokenId, 0, addr);
    }

    function checkIfOwnsUnderlying(uint tokenId) internal view returns (bool) {
        return CryptoPunksMarketInterface(underlying).punkIndexToAddress(tokenId) == address(this);
    }

    function doTransferIn(address /* from */, uint tokenId) internal { // underlying transfer in
        CryptoPunksMarketInterface(underlying).buyPunk.value(0)(tokenId);
        assert(checkIfOwnsUnderlying(tokenId));
    }

    function doTransferOut(address to, uint tokenId) internal { // underlying transfer out
        CryptoPunksMarketInterface token = CryptoPunksMarketInterface(underlying);
        token.transferPunk(to, tokenId);
        assert(token.punkIndexToAddress(tokenId) == to);
    }
}
