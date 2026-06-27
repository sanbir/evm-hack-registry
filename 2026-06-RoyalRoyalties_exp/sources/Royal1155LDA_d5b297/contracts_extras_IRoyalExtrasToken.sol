// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

/**
 * @title IRoyalExtrasToken
 * @author Royal
 *
 * @notice Specifies the callback functions that a token contract must implement in order to
 *  integrate with the redeemable token extras interface specified by IRoyalExtras.
 */
interface IRoyalExtrasToken {

    /**
     * @notice Callback function to be called when a new extra is registered to a set of tokens.
     */
    function onExtraRegistered(
        uint256 extraId,
        address registerer,
        uint256 startCanonicalTokenId,
        uint256 endCanonicalTokenId
    )
        external;

    /**
     * @notice Callback function to be called when an extra is redeemed.
     */
    function onExtraRedeemed(
        uint256 extraId,
        uint256 tokenId,
        address redeemer
    )
        external;

    /**
     * @notice Returns the “canonical” form of a token ID, which does not change even as extras
     *  are redeemed for a token.
     */
    function getCanonicalTokenId(
        uint256 tokenId
    )
        external
        view
        returns (uint256);
}
