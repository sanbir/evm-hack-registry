//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import { AccessControlUpgradeableGapless } from "../dependencies/openzeppelin/v4_7_0/AccessControlUpgradeableGapless.sol";
import { ERC1155UpgradeableGapless } from "../dependencies/openzeppelin/v4_7_0/ERC1155UpgradeableGapless.sol";
import { IERC165Upgradeable } from "../dependencies/openzeppelin/v4_7_0/IERC165Upgradeable.sol";
import { OwnableUpgradeableGapless } from "../dependencies/openzeppelin/v4_7_0/OwnableUpgradeableGapless.sol";
import { PausableUpgradeable } from "../dependencies/openzeppelin/v4_7_0/PausableUpgradeable.sol";

import { IRoyal1155LDA } from "./IRoyal1155LDA.sol";
import { IRoyalExtrasToken } from "../extras/IRoyalExtrasToken.sol";
import { ILdaTransferHook } from "../interfaces/ILdaTransferHook.sol";
import { IERC1155PermitUpgradeable } from "../lib/interfaces/IERC1155PermitUpgradeable.sol";
import { ERC1155PermitUpgradeableModifiedGaps } from "../lib/ERC1155PermitUpgradeableModifiedGaps.sol";
import { __Gap4, __Gap44 } from "../lib/Gaps.sol";
import { RoyalUtil } from "../shared/RoyalUtil.sol";

/**
 * @title Royal1155LDA
 * @author Royal
 *
 * @notice Implementation of Royal.io LDAs (Limited Digital Assets) as ERC-1155 tokens.
 *
 *  See https://eips.ethereum.org/EIPS/eip-1155
 *
 *  LDA token IDs (“LDA IDs”) are made up of three parts:
 *
 *    1. Tier ID: Denotes the collection that this token belongs to.
 *       For example -- editions typically correspond to a single musical work
 *       (song or album) by an artist, and each edition is typically split into
 *       multiple tiers such as GOLD, PLATINUM, and DIAMOND. Each of these
 *       tiers has a tier ID that is global across Royal LDAs on all chains.
 *
 *    2. Version: Represents the version, which may change with certain significant events such as
 *       the redemption of token extras. Including the version in the LDA ID ensures that
 *       marketplace bids and asks are invalidated when the token version changes.
 *
 *    3. Token ID: Represents the token number within the specific tier. We generally start
 *       at token #1 and count up to the tier max supply, but that is not strictly necessary.
 *
 *  These parts are laid out in the uint256 LDA token ID (the “LDA ID”) as follows:
 *
 *   MSB                                                 LSB
 *    [ tier_id             | version | token_id          ]
 *    [ **** **** **** **** | **      | ** **** **** **** ]
 *    [ 128 bits            | 16 bits | 112 bits          ]
 */
contract Royal1155LDA is
    ERC1155PermitUpgradeableModifiedGaps,
    PausableUpgradeable,
    OwnableUpgradeableGapless,
    __Gap4,
    AccessControlUpgradeableGapless,
    __Gap44,
    IRoyal1155LDA,
    IRoyalExtrasToken
{
    // -------------------- Events -------------------- //

    // Note: Recommend deprecating/removing this event.
    event NewTier(
        uint128 indexed tierID
    );

    // Note: Intentionally tierId instead of tierID.
    event TierConfigured(
        uint128 indexed tierId,
        uint256 maxSupply
    );

    // Note: Recommend deprecating/removing this event.
    event TierExhausted(
        uint128 indexed tierID
    );

    event SetExtrasContract(
        address extrasContract
    );

    event SetRoyaltiesContract(
        address royaltiesContract
    );

    // -------------------- Constants -------------------- //

    bytes32 public constant PERMIT_SPENDER_ROLE = keccak256("PERMIT_SPENDER_ROLE");

    // -------------------- Storage -------------------- //

    /// @custom:oz-renamed-from _contractMetadataURI
    string internal _CONTRACT_METADATA_URI_;

    /// @dev Mapping (tierId) => max supply for this tier
    /// @custom:oz-renamed-from tierMaxSupply
    mapping(uint128 => uint256) internal _MAX_SUPPLY_;

    /// @dev Mapping (tierId) => current supply for this tier.
    ///   NOTE: See also the comment below _TIER_ENUMERATION_.
    /// @custom:oz-renamed-from _tierCurrentSupply
    mapping(uint128 => uint256) internal _CURRENT_SUPPLY_;

    // MAPPINGS FOR MAINTAINING ISSUANCE_ID => LIST OF ADDRESSES HOLDING TOKENS (with repeats)
    // NOTE: These structures allow to enumerate the ldaId[] corresponding to a tierId. The
    //       addresses must then be looked up from _OWNERS_.

    /// @dev Mapping (ldaId) => owner address
    /// @custom:oz-renamed-from _owners
    mapping(uint256 => address) internal _OWNERS_;

    /// @dev Mapping (tierId) => (index) => (ldaId)
    ///  Tracks the LDA IDs that belong to a given tier.
    /// @custom:oz-renamed-from _ldasForTier
    mapping(uint128 => mapping(uint256 => uint256)) internal _TIER_ENUMERATION_;

    /// @dev (ldaId) => (index)
    ///  Tracks the index of the LDA ID in the _TIER_ENUMERATION_ list.
    /// @custom:oz-renamed-from _ldaIndexesForTier
    mapping(uint256 => uint256) internal _TIER_ENUMERATION_INDEX_;

    /// @dev Mapping (tierId) => (owner address) => (owned count)
    ///  Tracks the number of LDAs owned by a user within a particular tier.
    mapping(uint256 => mapping(address => uint256)) internal _BALANCES_;

    /// @dev Mapping (tierId) => (owner address) => (owned index) => (ldaId)
    ///  Tracks the LDA IDs owned by a user within a particular tier.
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _OWNED_TOKENS_;

    /// @dev Mapping (ldaId) => (owned index)
    ///  Tracks the index of the LDA ID in the _OWNED_TOKENS_ list.
    mapping(uint256 => uint256) internal _OWNED_TOKENS_INDEX_;

    /// @dev Indicates whether the backfill of `_OWNED_TOKENS_` was completed.
    bool internal _IS_OWNED_TOKENS_BACKFILL_COMPLETE_;

    /// @dev Address of the extras contract.
    address internal _EXTRAS_CONTRACT_;

    /// @dev Address of the royalties contract.
    address internal _ROYALTIES_CONTRACT_;

    /// @dev Storage slot that was used only on the testnet deployment.
    /// @custom:oz-renamed-from _GLOBAL_OPERATOR_
    mapping(address => bool) internal _GLOBAL_OPERATOR__DEPRECATED_;

    // ------------------ Constructor ------------------ //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------- Initializers -------------------- //

    function initialize(
        string memory tokenMetadataUri,
        string memory contractMetadataUri
    )
        external
        initializer
    {
        __Context_init_unchained();
        __Pausable_init_unchained();
        __Ownable_init_unchained();
        __ERC1155_init_unchained(tokenMetadataUri);
        _CONTRACT_METADATA_URI_ = contractMetadataUri;
    }

    function initializeV0_5_3()
        external
        reinitializer(2)
    {
        __EIP712_init_unchained("Royal LDAs", "1");
    }

    function initializeV0_5_6(
        address admin,
        address[] calldata permitSpenders
    )
        external
        reinitializer(3)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < permitSpenders.length;) {
            _grantRole(PERMIT_SPENDER_ROLE, permitSpenders[i]);
            unchecked { ++i; }
        }
    }

    // -------------------- Owner-Only Functions -------------------- //

    function pause()
        external
        onlyOwner
        whenNotPaused
    {
        _pause();
    }

    function unpause()
        external
        onlyOwner
        whenPaused
    {
        _unpause();
    }

    /**
     * @notice Setter for {_EXTRAS_CONTRACT_} that defines the address for the extras contract.
     */
    function setExtrasContract(
        address newExtrasContract
    )
        external
        onlyOwner
    {
        _EXTRAS_CONTRACT_ = newExtrasContract;
        emit SetExtrasContract(newExtrasContract);
    }

    /**
     * @notice Setter for {_ROYALTIES_CONTRACT_} that defines the address for the extras contract.
     */
    function setRoyaltiesContract(
        address newRoyaltiesContract
    )
        external
        onlyOwner
    {
        _ROYALTIES_CONTRACT_ = newRoyaltiesContract;
        emit SetRoyaltiesContract(newRoyaltiesContract);
    }

    function updateContractMetadataURI(
        string memory contractUri
    )
        external
        onlyOwner
        whenNotPaused
    {
        _CONTRACT_METADATA_URI_ = contractUri;
    }

    function updateTokenURI(
        string calldata tokenUri
    )
        external
        onlyOwner
    {
        _setURI(tokenUri);
    }

    function completeOwnedTokensBackfill()
        external
        onlyOwner
    {
        _IS_OWNED_TOKENS_BACKFILL_COMPLETE_ = true;
    }

    /**
     * @notice Called by the owner to backfill the mapping of owned token counts by user.
     */
    function setOwnedTokens(
        uint128 tierId,
        address[] calldata owners,
        uint256[][] calldata ownedTokens
    )
        external
        onlyOwner
    {
        require(
            !_IS_OWNED_TOKENS_BACKFILL_COMPLETE_,
            "Backfill is complete"
        );
        require(
            owners.length == ownedTokens.length,
            "Params length mismatch"
        );
        for (uint256 i = 0; i < owners.length; i++) {
            address owner = owners[i];
            uint256[] memory ownerOwnedTokens = ownedTokens[i];

            _BALANCES_[tierId][owner] = ownerOwnedTokens.length;

            for (uint256 j = 0; j < ownerOwnedTokens.length; j++) {
                uint256 ldaId = ownerOwnedTokens[j];
                _OWNED_TOKENS_[tierId][owner][j] = ldaId;
                _OWNED_TOKENS_INDEX_[ldaId] = j;
            }
        }
    }

    /**
     * @notice Create a tier of an LDA. In order for an LDA to be minted, it must
     *  belong to a valid tier that has not yet reached its max supply.
     */
    function createTier(
        uint128 tierId,
        uint256 maxSupply
    )
        external
        onlyOwner
        whenNotPaused
    {
        require(
            !this.tierExists(tierId),
            "Tier already exists"
        );
        require(
            tierId != 0 && maxSupply != 0,
            "Invalid tier definition"
        );

        _MAX_SUPPLY_[tierId] = maxSupply;

        // Legacy event.
        emit NewTier(tierId);

        emit TierConfigured(tierId, maxSupply);
    }

    /**
     * @notice Update the max supply of a tier.
     *
     *  The max supply cannot decrease below the current supply.
     */
    function updateTier(
        uint128 tierId,
        uint256 maxSupply
    )
        external
        onlyOwner
        whenNotPaused
    {
        require(
            this.tierExists(tierId),
            "Tier does not exist"
        );
        require(
            maxSupply != 0 && maxSupply >= _CURRENT_SUPPLY_[tierId],
            "Invalid max supply"
        );

        _MAX_SUPPLY_[tierId] = maxSupply;

        emit TierConfigured(tierId, maxSupply);

        if (maxSupply == _CURRENT_SUPPLY_[tierId]) {
            emit TierExhausted(tierId);
        }
    }

    function mintLDAToOwner(
        address recipient,
        uint256 ldaId,
        bytes calldata data
    )
        external
        onlyOwner
        whenNotPaused
    {
        require(
            _OWNERS_[ldaId] == address(0),
            "LDA already minted"
        );
        (uint128 tierId,,) = RoyalUtil.decomposeLDA_ID(ldaId);
        require(
            this.mintable(tierId),
            "Tier not mintable"
        );

        // Update current supply before minting to prevent reentrancy attacks
        _CURRENT_SUPPLY_[tierId] += 1;
        _mint(recipient, ldaId, 1, data);

        // Emit an event when the max supply is reached.
        if (_CURRENT_SUPPLY_[tierId] == _MAX_SUPPLY_[tierId]) {
            emit TierExhausted(tierId);
        }
    }

    /**
     * @notice Bulk mint a list of LDAs from a given tier.
     */
    function bulkMintTierLDAsToOwner(
        address recipient,
        uint256[] calldata ldaIds,
        bytes calldata data
    )
        external
        onlyOwner
        whenNotPaused
    {
        require(
            ldaIds.length >= 1,
            "empty ldaIDs list"
        );

        // Check this tier is mintable
        (uint128 tierId,,) = RoyalUtil.decomposeLDA_ID(ldaIds[0]);
        require(
            this.tierExists(tierId),
            "Tier not mintable"
        );
        require(
            (_CURRENT_SUPPLY_[tierId] + ldaIds.length) <= _MAX_SUPPLY_[tierId],
            "Too many tokens to mint"
        );

        // Check all LDAs are unminted
        for (uint256 i = 0; i < ldaIds.length; i++) {
            require(
                _OWNERS_[ldaIds[i]] == address(0),
                "LDA already minted"
            );
            (uint128 curTierId,,) = RoyalUtil.decomposeLDA_ID(ldaIds[i]);
            require(
                curTierId == tierId,
                "not all tiers are the same"
            );
        }

        // We always just want 1 of each token
        uint256[] memory amounts = new uint256[](ldaIds.length);
        for (uint256 i = 0; i < ldaIds.length; i++) {
            amounts[i] = 1;
        }

        // Update current supply before minting to prevent reentrancy attacks
        _CURRENT_SUPPLY_[tierId] += ldaIds.length;
        // Issue mint
        _mintBatch(recipient, ldaIds, amounts, data);

        // Emit an event when the max supply is reached.
        if (_CURRENT_SUPPLY_[tierId] == _MAX_SUPPLY_[tierId]) {
            emit TierExhausted(tierId);
        }
    }

    // -------------------- Other Access-Controlled Functions -------------------- //

    function onExtraRedeemed(
        uint256 /* extraId */,
        uint256 ldaId,
        address redeemer
    )
        external
        override
    {
        address tokenOwner = _OWNERS_[ldaId];

        require(
            _msgSender() == _EXTRAS_CONTRACT_,
            "redemptions only from extras contract"
        );
        require(
            tokenOwner != address(0),
            "token DNE"
        );
        require(
            (tokenOwner == redeemer) || isApprovedForAll(tokenOwner, redeemer),
            "redemption by approved addresses only"
        );

        // Bump version number in the token ID (a.k.a. LDA ID).
        (uint128 tierId, uint256 version, uint128 tokenId) = RoyalUtil.decomposeLDA_ID(
            ldaId
        );
        uint256 newLdaId = RoyalUtil.composeLDA_ID(tierId, ++version, tokenId);

        // Burn and remint with new incremented version number.
        bytes memory emptyData;
        _burn(tokenOwner, ldaId, 1);
        _mint(tokenOwner, newLdaId, 1, emptyData);
    }

    // -------------------- Other External Functions -------------------- //

    function getExtrasContract()
        external
        view
        returns (address)
    {
        return _EXTRAS_CONTRACT_;
    }

    function getRoyaltiesContract()
        external
        view
        returns (address)
    {
        return _ROYALTIES_CONTRACT_;
    }

    function contractURI()
        external
        view
        returns (string memory)
    {
        return _CONTRACT_METADATA_URI_;
    }

    function getIsOwnedTokensBackfillComplete()
        external
        view
        returns (bool)
    {
        return _IS_OWNED_TOKENS_BACKFILL_COMPLETE_;
    }

    function getTierTotalSupply(
        uint128 tierId
    )
        external
        view
        override
        returns (uint256)
    {
        return _MAX_SUPPLY_[tierId];
    }

    /// @dev Legacy alias for getTierTotalSupply().
    function tierMaxSupply(
        uint128 tierId
    )
        external
        view
        returns (uint256)
    {
        return _MAX_SUPPLY_[tierId];
    }

    /**
     * @notice Has this tier been initialized?
     */
    function tierExists(
        uint128 tierId
    )
        external
        view
        override
        returns (bool)
    {
        return _MAX_SUPPLY_[tierId] != 0;
    }

    /**
     * @notice Check if the tier is currently mintable.
     */
    function mintable(
        uint128 tierId
    )
        external
        view
        override
        returns (bool)
    {
        return _CURRENT_SUPPLY_[tierId] < _MAX_SUPPLY_[tierId];
    }

    /**
     * @notice Has the given LDA been minted?
     */
    function exists(
        uint256 ldaId
    )
        external
        view
        returns (bool)
    {
        return _OWNERS_[ldaId] != address(0);
    }

    /**
     * @notice What address owns the given ldaID?
     */
    function ownerOf(
        uint256 ldaId
    )
        external
        view
        returns (address)
    {
        require(
            _OWNERS_[ldaId] != address(0),
            "LDA DNE"
        );
        return _OWNERS_[ldaId];
    }

    /**
     * @notice Get the number of LDAs owned by a user within a particular tier.
     *
     *  IMPORTANT: Assumes that the max supply of each LDA ID in the tier is 1.
     */
    function tierBalanceOf(
        uint128 tierId,
        address owner
    )
        external
        view
        override
        returns (uint256)
    {
        return _BALANCES_[tierId][owner];
    }

    function tokenOfOwnerByIndex(
        uint128 tierId,
        address owner,
        uint256 index
    )
        external
        view
        returns (uint256)
    {
        require(
            index < _BALANCES_[tierId][owner],
            "Owner index out of bounds"
        );
        return _OWNED_TOKENS_[tierId][owner][index];
    }

    function getOwnedTokens(
        uint128 tierId,
        address owner
    )
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 balance = _BALANCES_[tierId][owner];
        uint256[] memory ownedTokens = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            ownedTokens[i] = _OWNED_TOKENS_[tierId][owner][i];
        }
        return ownedTokens;
    }

    /**
     * @notice Compose a raw ldaID from its two composite parts.
     */
    function composeLDA_ID(
        uint128 tierId,
        uint256 version,
        uint128 tokenId
    )
        external
        pure
        returns (
            uint256 ldaID
        )
    {
        return RoyalUtil.composeLDA_ID(tierId, version, tokenId);
    }

    /**
     * @notice Decompose a raw ldaID into its two composite parts.
     */
    function decomposeLDA_ID(
        uint256 ldaId
    )
        external
        pure
        returns (
            uint128 tierID,
            uint256 version,
            uint128 tokenID
        )
    {
        return RoyalUtil.decomposeLDA_ID(ldaId);
    }

    /**
     * @notice Zeros out the token version and returns a Royal LDA ID V1.
     */
    function getCanonicalTokenId(
        uint256 tokenId
    )
        external
        pure
        override
        returns(
            uint256
        )
    {
        return RoyalUtil.getCanonicalTokenId(tokenId);
    }

    function onExtraRegistered(
        uint256 /* extraId */,
        address /* registerer */,
        uint256 /* startCanonicalTokenId */,
        uint256 /* endCanonicalTokenId */
    )
        external
        pure
        override
    {}

    // -------------------- Public Functions -------------------- //

    function permit(
        address owner,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        override(
            ERC1155PermitUpgradeableModifiedGaps,
            IERC1155PermitUpgradeable
        )
    {
        require(
            hasRole(PERMIT_SPENDER_ROLE, spender),
            "Invalid permit spender"
        );
        super.permit(owner, spender, deadline, v, r, s);
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(
            AccessControlUpgradeableGapless,
            ERC1155UpgradeableGapless,
            IERC165Upgradeable
        )
        returns (bool)
    {
        return (
            AccessControlUpgradeableGapless.supportsInterface(interfaceId) ||
            ERC1155UpgradeableGapless.supportsInterface(interfaceId)
        );
    }

    // -------------------- Internal Functions -------------------- //

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    )
        internal
        virtual
        override
    {
        // Iterate over all LDAs being transferred
        for (uint256 i; i < ids.length; i++) {
            uint256 ldaId = ids[i];

            // Get the tier ID.
            (uint128 tierId, ,) = RoyalUtil.decomposeLDA_ID(ldaId);

            // Call the callback on the Royalties contract.
            //
            // IMPORTANT: This must happen before any bookkeeping like `_OWNED_TOKENS_` is updated.
            if (_ROYALTIES_CONTRACT_ != address(0)) {
                ILdaTransferHook(_ROYALTIES_CONTRACT_).beforeLdaTransfer(from, to, tierId);
            }

            // Self-transfer: skip everything that follows.
            if (from == to) {
                continue;
            }

            // Token leaves a wallet: update balance and remove token from owner enumeration.
            if (from != address(0)) {
                uint256 balance = _BALANCES_[tierId][from];

                // Special case: If backfill is ongoing AND balance is zero, do not update.
                if (_IS_OWNED_TOKENS_BACKFILL_COMPLETE_ || balance != 0) {
                    require(
                        balance != 0,
                        "ERC1155: insufficient balance for transfer"
                    );

                    // Remove from owned tokens list using swap-and-pop method.
                    uint256 lastTokenIndex = balance - 1;
                    uint256 removeTokenIndex = _OWNED_TOKENS_INDEX_[ldaId];

                    if (lastTokenIndex != removeTokenIndex) {
                        uint256 lastTokenId = _OWNED_TOKENS_[tierId][from][lastTokenIndex];
                        _OWNED_TOKENS_[tierId][from][removeTokenIndex] = lastTokenId;
                        _OWNED_TOKENS_INDEX_[lastTokenId] = removeTokenIndex;
                    }

                    delete _OWNED_TOKENS_[tierId][from][lastTokenIndex];
                    delete _OWNED_TOKENS_INDEX_[ldaId]; // NOTE: This deletion is optional.

                    _BALANCES_[tierId][from] = lastTokenIndex;
                }
            }

            // Token enters a wallet: update balance and add token to owner enumeration.
            if (to != address(0)) {
                uint256 oldBalance = _BALANCES_[tierId][to];
                _OWNED_TOKENS_[tierId][to][oldBalance] = ldaId;
                _OWNED_TOKENS_INDEX_[ldaId] = oldBalance;

                _BALANCES_[tierId][to] = oldBalance + 1;
            }

            if (from == address(0)) {
                // This is a mint operation
                // Add this LDA to the `to` address state
                _addTokenToTierTracking(to, ldaId, tierId);

            } else {
                // If this is a transfer to a different address.
                _OWNERS_[ldaId] = to;
            }

            if (to == address(0)) {
                // NOTE: no burn() is currently implemented
                // Remove LDA from being associated with its
                _removeLDAFromTierTracking(from, ldaId, tierId);
            }
        }

        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    function _addTokenToTierTracking(
        address to,
        uint256 ldaId,
        uint128 tierId
    )
        internal
    {
        uint256 ldaIndexForThisTier = _CURRENT_SUPPLY_[tierId];
        _TIER_ENUMERATION_[tierId][ldaIndexForThisTier] = ldaId;

        // Track where this ldaId is in the "list"
        _TIER_ENUMERATION_INDEX_[ldaId] = ldaIndexForThisTier;

        _OWNERS_[ldaId] = to;
    }

    /**
     * @dev Inspired by https://github.com/OpenZeppelin/openzeppelin-contracts/blob/6f23efa97056e643cefceedf86fdf1206b6840fb/contracts/token/ERC721/extensions/ERC721Enumerable.sol#L118
     */
    function _removeLDAFromTierTracking(
        address from,
        uint256 ldaId,
        uint128 tierId
    )
        internal
    {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastLdaIndex = _CURRENT_SUPPLY_[tierId] - 1;
        uint256 tokenIndex = _TIER_ENUMERATION_INDEX_[ldaId];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastLdaIndex) {
            uint256 lastLdaId = _TIER_ENUMERATION_[tierId][lastLdaIndex];

            _TIER_ENUMERATION_[tierId][tokenIndex] = lastLdaId; // Move the last LDA to the slot of the to-delete LDA
            _TIER_ENUMERATION_INDEX_[lastLdaId] = tokenIndex; // Update the moved LDA's index

        }
        // This also deletes the contents at the last position of the array
        delete _TIER_ENUMERATION_INDEX_[ldaId];
        delete _TIER_ENUMERATION_[tierId][lastLdaIndex];

        _OWNERS_[ldaId] = from;
    }
}
