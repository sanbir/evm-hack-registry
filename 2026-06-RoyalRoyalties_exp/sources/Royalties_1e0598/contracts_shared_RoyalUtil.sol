//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @title RoyalUtil
 * @author Royal
 * @notice Supports common operations on LDA IDs.
 *
 * ROYAL LDA ID FORMAT V2 OVERVIEW
 *
 *  The ID of a royal LDA contains 3 pieces of information:
 *
 *    1. Tier ID: Denotes te tier that this token belongs to (e.g. GOLD, PLATINUM, DIAMOND).
 *       A tier ID is globally unique across all Royal drops.
 *
 *    2. Version: Represents the version, which may change with certain significant events such as
 *       the redemption of token extras. Including the version in the LDA ID ensures that
 *       marketplace bids and asks are invalidated when the token version changes.
 *
 *    3. Token ID: Represents the token number within the specific tier. We generally start
 *       at token #1 and count up to the tier max supply, but that is not strictly necessary.
 *
 *
 *  These parts are laid out in the uint256 LDA ID as follows:
 *
 *   MSB                                                 LSB
 *    [ tier_id             | version | token_id          ]
 *    [ **** **** **** **** | **      | ** **** **** **** ]
 *    [ 128 bits            | 16 bits | 112 bits          ]
 */
library RoyalUtil {

    uint256 constant UPPER_ISSUANCE_ID_MASK = uint256(type(uint128).max) << 128;
    uint256 constant LOWER_TOKEN_ID_MASK = type(uint112).max;
    uint256 constant TOKEN_VERSION_MASK =
        uint256(type(uint128).max) ^ LOWER_TOKEN_ID_MASK;

    /**
     * @dev Compose an LDA ID from its composite parts.
     */
    function composeLDA_ID(
        uint128 tierID,
        uint256 version,
        uint128 tokenID
    )
        internal
        pure
        returns (uint256 ldaID)
    {
        require(
            tierID != 0 && tokenID != 0,
            "Invalid ldaID"
        ); // NOTE: TierID and TokenID > 0

        require(
            version <= type(uint16).max,
            "invalid version"
        );

        return (uint256(tierID) << 128) + (version << 112) + uint256(tokenID);
    }

    /**
     * @dev Decompose a raw LDA ID into its composite parts.
     */
    function decomposeLDA_ID(
        uint256 ldaID
    )
        internal
        pure
        returns (
            uint128 tierID,
            uint256 version,
            uint128 tokenID
        )
    {
        tierID = uint128(ldaID >> 128);
        tokenID = uint128(ldaID & LOWER_TOKEN_ID_MASK);
        version = (ldaID & TOKEN_VERSION_MASK) >> 112;
        require(
            tierID != 0 && tokenID != 0,
            "Invalid ldaID"
        ); // NOTE: TierID and TokenID > 0
    }

    /**
     * @notice Returns the “canonical” form of a token ID, which ignores the version part.
     */
    function getCanonicalTokenId(
        uint256 tokenID
    )
        internal
        pure
        returns (uint256)
    {
        return tokenID & (TOKEN_VERSION_MASK ^ type(uint256).max);
    }
}
