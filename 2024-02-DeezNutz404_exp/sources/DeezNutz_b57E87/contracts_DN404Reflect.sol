// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "./DN404Mirror.sol";

/// @title DN404
/// @notice DN404 is a hybrid ERC20 and ERC721 implementation that mints
/// and burns NFTs based on an account's ERC20 token balance.
///
/// @author vectorized.eth (@optimizoor)
/// @author Quit (@0xQuit)
/// @author Michael Amadi (@AmadiMichaels)
/// @author cygaar (@0xCygaar)
/// @author Thomas (@0xjustadev)
/// @author Harrison (@PopPunkOnChain)
///
/// @dev Note:
/// - The ERC721 data is stored in this base DN404 contract, however a
///   DN404Mirror contract ***MUST*** be deployed and linked during
///   initialization.
abstract contract DN404Reflect {
    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           EVENTS                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Emitted when `amount` tokens is transferred from `from` to `to`.
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @dev Emitted when `amount` tokens is approved by `owner` to be used by `spender`.
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    /// @dev Emitted when `target` sets their skipNFT flag to `status`.
    event SkipNFTSet(address indexed target, bool status);

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                        CUSTOM ERRORS                       */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Thrown when attempting to double-initialize the contract.
    error DNAlreadyInitialized();

    /// @dev Thrown when attempting to transfer or burn more tokens than sender's balance.
    error InsufficientBalance();

    /// @dev Thrown when a spender attempts to transfer tokens with an insufficient allowance.
    error InsufficientAllowance();

    /// @dev Thrown when minting an amount of tokens that would overflow the max tokens.
    error TotalSupplyOverflow();

    /// @dev Thrown when the caller for a fallback NFT function is not the mirror contract.
    error SenderNotMirror();

    /// @dev Thrown when attempting to transfer tokens to the zero address.
    error TransferToZeroAddress();

    /// @dev Thrown when the mirror address provided for initialization is the zero address.
    error MirrorAddressIsZero();

    /// @dev Thrown when the link call to the mirror contract reverts.
    error LinkMirrorContractFailed();

    /// @dev Thrown when setting an NFT token approval
    /// and the caller is not the owner or an approved operator.
    error ApprovalCallerNotOwnerNorApproved();

    /// @dev Thrown when transferring an NFT
    /// and the caller is not the owner or an approved operator.
    error TransferCallerNotOwnerNorApproved();

    /// @dev Thrown when transferring an NFT and the from address is not the current owner.
    error TransferFromIncorrectOwner();

    /// @dev Thrown when checking the owner or approved address for an non-existent NFT.
    error TokenDoesNotExist();

    /// @dev Amount of token balance that is equal to one NFT.
    uint256 internal _WAD;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         CONSTANTS                          */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev The maximum token ID allowed for an NFT.
    uint256 internal constant _MAX_TOKEN_ID = 0xffffffff;

    /// @dev The maximum possible token supply.
    uint256 internal constant _MAX_SUPPLY = 10 ** 18 * 0xffffffff - 1;

    /// @dev The flag to denote that the address data is initialized.
    uint8 internal constant _ADDRESS_DATA_INITIALIZED_FLAG = 1 << 0;

    /// @dev The flag to denote that the address should skip NFTs.
    uint8 internal constant _ADDRESS_DATA_SKIP_NFT_FLAG = 1 << 1;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          STORAGE                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Struct containing an address's token data and settings.
    struct AddressData {
        // Auxiliary data.
        uint88 aux;
        // Flags for `initialized` and `skipNFT`.
        uint8 flags;
        // The alias for the address. Zero means absence of an alias.
        uint32 addressAlias;
        // The number of NFT tokens.
        uint32 ownedLength;
        // The token balance in wei.
        uint96 balance;
        // tTotal for reflections
        uint256 tOwned;
        // rTotal for reflections
        uint256 rOwned;
        // Excluded from reflections
        bool isExcluded;
    }

    /// @dev A uint32 map in storage.
    struct Uint32Map {
        mapping(uint256 => uint256) map;
    }

    /// @dev Struct containing the base token contract storage.
    struct DN404Storage {
        // Current number of address aliases assigned.
        uint32 numAliases;
        // Next token ID to assign for an NFT mint.
        uint32 nextTokenId;
        // Total supply of minted NFTs.
        uint32 totalNFTSupply;
        // Total supply of tokens.
        uint96 totalSupply;
        // Total supply of tokens
        uint256 tTotal;
        // Reflections remaining
        uint256 rTotal;
        // Total transaction fees
        uint256 tFeeTotal;
        // Tax Fee (as percentage)
        uint256 taxFee;
        // Address of the NFT mirror contract.
        address mirrorERC721;
        // Mapping of a user alias number to their address.
        mapping(uint32 => address) aliasToAddress;
        // Mapping of user operator approvals for NFTs.
        mapping(address => mapping(address => bool)) operatorApprovals;
        // Mapping of NFT token approvals to approved operators.
        mapping(uint256 => address) tokenApprovals;
        // Mapping of user allowances for token spenders.
        mapping(address => mapping(address => uint256)) allowance;
        // Mapping of NFT token IDs owned by an address.
        mapping(address => Uint32Map) owned;
        // Even indices: owner aliases. Odd indices: owned indices.
        Uint32Map oo;
        // Mapping of user account AddressData
        mapping(address => AddressData) addressData;
        // array of excluded addresses
        address[] excluded;
        // Determines whether setTaxFee and ExcludeAccount can be called
        bool functionsRenounced;
        // Opens transfers for everyone
        bool tradingEnabled;
    }

    /// @dev Returns a storage pointer for DN404Storage.
    function _getDN404Storage()
        internal
        pure
        virtual
        returns (DN404Storage storage $)
    {
        /// @solidity memory-safe-assembly
        assembly {
            // `uint72(bytes9(keccak256("DN404_STORAGE")))`.
            $.slot := 0xa20d6e21d0e5255308 // Truncate to 9 bytes to reduce bytecode size.
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         INITIALIZER                        */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Initializes the DN404 contract with an
    /// `initialTokenSupply`, `initialTokenOwner` and `mirror` NFT contract address.
    function _initializeDN404Reflect(
        uint256 initialTokenSupply,
        address initialSupplyOwner,
        address mirror,
        uint256 wad
    ) internal virtual {
        DN404Storage storage $ = _getDN404Storage();

        if ($.nextTokenId != 0) revert DNAlreadyInitialized();

        if (mirror == address(0)) revert MirrorAddressIsZero();
        _linkMirrorContract(mirror);

        $.nextTokenId = 1;
        $.mirrorERC721 = mirror;
        _WAD = wad;
        if (initialTokenSupply > 0) {
            if (initialSupplyOwner == address(0))
                revert TransferToZeroAddress();
            if (initialTokenSupply > _MAX_SUPPLY) revert TotalSupplyOverflow();

            $.totalSupply = uint96(initialTokenSupply);
            $.tTotal = uint256(initialTokenSupply);
            uint256 MAX = ~uint256(0);
            $.rTotal = (MAX - (MAX % $.tTotal));
            AddressData storage initialOwnerAddressData = _addressData(
                initialSupplyOwner
            );
            initialOwnerAddressData.balance = uint96(initialTokenSupply);
            initialOwnerAddressData.rOwned = $.rTotal;

            emit Transfer(address(0), initialSupplyOwner, initialTokenSupply);

            _setSkipNFT(initialSupplyOwner, true);
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*               METADATA FUNCTIONS TO OVERRIDE               */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Returns the name of the token.
    function name() public view virtual returns (string memory);

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual returns (string memory);

    /// @dev Returns the Uniform Resource Identifier (URI) for token `id`.
    function tokenURI(
        uint256 id
    ) public view virtual returns (string memory result);

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                      ERC20 OPERATIONS                      */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Returns the decimals places of the token. Always 18.
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /// @dev Returns the amount of tokens in existence.
    function totalSupply() public view virtual returns (uint256) {
        return uint256(_getDN404Storage().totalSupply);
    }

    /// @dev Returns the amount of tokens owned by `owner`
    ///      Updated for reflections logic
    function balanceOf(address owner) public view virtual returns (uint256) {
        AddressData storage ownerAddressData = _getDN404Storage().addressData[
            owner
        ];
        if (ownerAddressData.isExcluded) return ownerAddressData.tOwned;
        return tokenFromReflection(ownerAddressData.rOwned);
    }

    /// @dev Returns the amount of tokens that `spender` can spend on behalf of `owner`.
    function allowance(
        address owner,
        address spender
    ) public view returns (uint256) {
        return _getDN404Storage().allowance[owner][spender];
    }

    /// @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    ///
    /// Emits a {Approval} event.
    function approve(
        address spender,
        uint256 amount
    ) public virtual returns (bool) {
        DN404Storage storage $ = _getDN404Storage();

        $.allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    /// @dev Transfer `amount` tokens from the caller to `to`.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    ///
    /// Emits a {Transfer} event.
    function transfer(
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @dev Transfers `amount` tokens from `from` to `to`.
    ///
    /// Note: Does not update the allowance if it is the maximum uint256 value.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    /// - The caller must have at least `amount` of allowance to transfer the tokens of `from`.
    ///
    /// Emits a {Transfer} event.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        DN404Storage storage $ = _getDN404Storage();
        uint256 allowed = $.allowance[from][msg.sender];

        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientAllowance();
            unchecked {
                $.allowance[from][msg.sender] = allowed - amount;
            }
        }

        _transfer(from, to, amount);

        return true;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                   REFLECTION OPERATIONS                    */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev reflects sender's wallet
    function reflect(uint256 tAmount) public {
        DN404Storage storage $ = _getDN404Storage();
        address sender = msg.sender;
        AddressData storage senderAddressData = _addressData(sender);
        require(
            !senderAddressData.isExcluded,
            "Excluded addresses cannot call this function"
        );
        (uint256 rAmount, , , , ) = _getValues(tAmount);
        senderAddressData.rOwned = senderAddressData.rOwned - rAmount;
        $.rTotal = $.rTotal - rAmount;
        $.tFeeTotal = $.tFeeTotal + tAmount;
    }
    /// @dev returns rAmount from amount of tokens
    function reflectionFromToken(
        uint256 tAmount,
        bool deductTransferFee
    ) public view returns (uint256) {
        require(
            tAmount <= _getDN404Storage().tTotal,
            "Amount must be less than supply"
        );
        if (!deductTransferFee) {
            (uint256 rAmount, , , , ) = _getValues(tAmount);
            return rAmount;
        } else {
            (, uint256 rTransferAmount, , , ) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    ///@dev returns token amount from rTotal (used for balanceOf)
    function tokenFromReflection(
        uint256 rAmount
    ) public view returns (uint256) {
        require(
            rAmount <= _getDN404Storage().rTotal,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                  INTERNAL MINT FUNCTIONS                   */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Mints `amount` tokens to `to`, increasing the total supply.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Emits a {Transfer} event.
    function _mint(address to, uint256 amount) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        DN404Storage storage $ = _getDN404Storage();

        AddressData storage toAddressData = _addressData(to);

        unchecked {
            uint256 currentTokenSupply = uint256($.totalSupply) + amount;
            if (amount > _MAX_SUPPLY || currentTokenSupply > _MAX_SUPPLY) {
                revert TotalSupplyOverflow();
            }
            $.totalSupply = uint96(currentTokenSupply);

            uint256 toBalance = toAddressData.balance + amount;
            toAddressData.balance = uint96(toBalance);

            if (toAddressData.flags & _ADDRESS_DATA_SKIP_NFT_FLAG == 0) {
                Uint32Map storage toOwned = $.owned[to];
                uint256 toIndex = toAddressData.ownedLength;
                uint256 toEnd = toBalance / _WAD;
                _PackedLogs memory packedLogs = _packedLogsMalloc(
                    _zeroFloorSub(toEnd, toIndex)
                );

                if (packedLogs.logs.length != 0) {
                    uint256 maxNFTId = $.totalSupply / _WAD;
                    uint32 toAlias = _registerAndResolveAlias(
                        toAddressData,
                        to
                    );
                    uint256 id = $.nextTokenId;
                    $.totalNFTSupply += uint32(packedLogs.logs.length);
                    toAddressData.ownedLength = uint32(toEnd);
                    // Mint loop.
                    do {
                        while (_get($.oo, _ownershipIndex(id)) != 0) {
                            if (++id > maxNFTId) id = 1;
                        }
                        _set(toOwned, toIndex, uint32(id));
                        _setOwnerAliasAndOwnedIndex(
                            $.oo,
                            id,
                            toAlias,
                            uint32(toIndex++)
                        );
                        _packedLogsAppend(packedLogs, to, id, 0);
                        if (++id > maxNFTId) id = 1;
                    } while (toIndex != toEnd);
                    $.nextTokenId = uint32(id);
                    _packedLogsSend(packedLogs, $.mirrorERC721);
                }
            }
        }
        emit Transfer(address(0), to, amount);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                  INTERNAL BURN FUNCTIONS                   */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Burns `amount` tokens from `from`, reducing the total supply.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Emits a {Transfer} event.
    function _burn(address from, uint256 amount) internal virtual {
        DN404Storage storage $ = _getDN404Storage();

        AddressData storage fromAddressData = _addressData(from);

        uint256 fromBalance = fromAddressData.balance;
        if (amount > fromBalance) revert InsufficientBalance();

        uint256 currentTokenSupply = $.totalSupply;

        unchecked {
            fromBalance -= amount;
            fromAddressData.balance = uint96(fromBalance);
            currentTokenSupply -= amount;
            $.totalSupply = uint96(currentTokenSupply);

            Uint32Map storage fromOwned = $.owned[from];
            uint256 fromIndex = fromAddressData.ownedLength;
            uint256 nftAmountToBurn = _zeroFloorSub(
                fromIndex,
                fromBalance / _WAD
            );

            if (nftAmountToBurn != 0) {
                $.totalNFTSupply -= uint32(nftAmountToBurn);

                _PackedLogs memory packedLogs = _packedLogsMalloc(
                    nftAmountToBurn
                );

                uint256 fromEnd = fromIndex - nftAmountToBurn;
                // Burn loop.
                do {
                    uint256 id = _get(fromOwned, --fromIndex);
                    _setOwnerAliasAndOwnedIndex($.oo, id, 0, 0);
                    delete $.tokenApprovals[id];
                    _packedLogsAppend(packedLogs, from, id, 1);
                } while (fromIndex != fromEnd);

                fromAddressData.ownedLength = uint32(fromIndex);
                _packedLogsSend(packedLogs, $.mirrorERC721);
            }
        }
        emit Transfer(from, address(0), amount);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                INTERNAL TRANSFER FUNCTIONS                 */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Moves `amount` of tokens from `from` to `to`.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Emits a {Transfer} event.
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        DN404Storage storage $ = _getDN404Storage();

        AddressData storage fromAddressData = _addressData(from);
        AddressData storage toAddressData = _addressData(to);

        _TransferTemps memory t;
        t.fromOwnedLength = fromAddressData.ownedLength;
        t.toOwnedLength = toAddressData.ownedLength;
        t.rOwnedFrom = fromAddressData.rOwned;
        t.rOwnedTo = toAddressData.rOwned;
        t.fromBalance = this.balanceOf(from);
        t.toBalance = this.balanceOf(to);
        if (amount > t.fromBalance) revert InsufficientBalance();

        unchecked {
            // Reflections transfer logic
            (
                uint256 rAmount,
                uint256 rTransferAmount,
                uint256 rFee,
                uint256 tTransferAmount,
                uint256 tFee
            ) = _getValues(amount);
  
            // Transfer from excluded address
            if (fromAddressData.isExcluded && !toAddressData.isExcluded) {
                t.tOwnedFrom = fromAddressData.tOwned - amount;
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = t.tOwnedFrom;
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Transfer to excluded address
            else if (!fromAddressData.isExcluded && toAddressData.isExcluded) {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                t.tOwnedTo = toAddressData.tOwned + tTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = t.tOwnedTo;
            }
            // Transfer between non-excluded addresses
            else if (!fromAddressData.isExcluded && !toAddressData.isExcluded) {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Transfer between both excluded addresses
            else if (fromAddressData.isExcluded && toAddressData.isExcluded) {
                t.tOwnedFrom = fromAddressData.tOwned - amount;
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                t.tOwnedTo = toAddressData.tOwned + tTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = t.tOwnedFrom;
                t.toBalance = t.tOwnedTo;
            } else {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Reflect fees to all token holders
            _reflectFee(rFee, tFee);
            // Update address data rOwned and tOwned
            fromAddressData.rOwned = t.rOwnedFrom;
            toAddressData.rOwned = t.rOwnedTo;
            fromAddressData.tOwned = t.tOwnedFrom;
            toAddressData.tOwned = t.tOwnedTo;

            // Update address balances for nft transfer logic
            fromAddressData.balance = uint96(t.fromBalance);
            toAddressData.balance = uint96(t.toBalance);

            t.nftAmountToBurn = _zeroFloorSub(
                t.fromOwnedLength,
                t.fromBalance / _WAD
            );

            if (toAddressData.flags & _ADDRESS_DATA_SKIP_NFT_FLAG == 0) {
                if (from == to)
                    t.toOwnedLength = t.fromOwnedLength - t.nftAmountToBurn;
                t.nftAmountToMint = _zeroFloorSub(
                    t.toBalance / _WAD,
                    t.toOwnedLength
                );
            }

            _PackedLogs memory packedLogs = _packedLogsMalloc(
                t.nftAmountToBurn + t.nftAmountToMint
            );

            if (t.nftAmountToBurn != 0) {
                Uint32Map storage fromOwned = $.owned[from];
                uint256 fromIndex = t.fromOwnedLength;
                uint256 fromEnd = fromIndex - t.nftAmountToBurn;
                $.totalNFTSupply -= uint32(t.nftAmountToBurn);
                fromAddressData.ownedLength = uint32(fromEnd);
                // Burn loop.
                do {
                    uint256 id = _get(fromOwned, --fromIndex);
                    _setOwnerAliasAndOwnedIndex($.oo, id, 0, 0);
                    delete $.tokenApprovals[id];
                    _packedLogsAppend(packedLogs, from, id, 1);
                } while (fromIndex != fromEnd);
            }

            if (t.nftAmountToMint != 0) {
                Uint32Map storage toOwned = $.owned[to];
                uint256 toIndex = t.toOwnedLength;
                uint256 toEnd = toIndex + t.nftAmountToMint;
                uint32 toAlias = _registerAndResolveAlias(toAddressData, to);
                uint256 maxNFTId = $.totalSupply / _WAD;
                uint256 id = $.nextTokenId;
                $.totalNFTSupply += uint32(t.nftAmountToMint);
                toAddressData.ownedLength = uint32(toEnd);
                // Mint loop.
                do {
                    while (_get($.oo, _ownershipIndex(id)) != 0) {
                        if (++id > maxNFTId) id = 1;
                    }
                    _set(toOwned, toIndex, uint32(id));
                    _setOwnerAliasAndOwnedIndex(
                        $.oo,
                        id,
                        toAlias,
                        uint32(toIndex++)
                    );
                    _packedLogsAppend(packedLogs, to, id, 0);
                    if (++id > maxNFTId) id = 1;
                } while (toIndex != toEnd);
                $.nextTokenId = uint32(id);
            }

            if (packedLogs.logs.length != 0) {
                _packedLogsSend(packedLogs, $.mirrorERC721);
            }
        }
        // Should be taken care of by internal reflections transfer functions
        emit Transfer(from, to, amount);
    }

    /// @dev Transfers token `id` from `from` to `to`.
    ///
    /// Requirements:
    ///
    /// - Call must originate from the mirror contract.
    /// - Token `id` must exist.
    /// - `from` must be the owner of the token.
    /// - `to` cannot be the zero address.
    ///   `msgSender` must be the owner of the token, or be approved to manage the token.
    ///
    /// Emits a {Transfer} event.
    function _transferFromNFT(
        address from,
        address to,
        uint256 id,
        address msgSender
    ) internal virtual {
        DN404Storage storage $ = _getDN404Storage();
        if (to == address(0)) revert TransferToZeroAddress();

        address owner = $.aliasToAddress[_get($.oo, _ownershipIndex(id))];

        if (from != owner) revert TransferFromIncorrectOwner();

        if (msgSender != from) {
            if (!$.operatorApprovals[from][msgSender]) {
                if (msgSender != $.tokenApprovals[id]) {
                    revert TransferCallerNotOwnerNorApproved();
                }
            }
        }

        AddressData storage fromAddressData = _addressData(from);
        AddressData storage toAddressData = _addressData(to);

        // Transfer without taking reflection fee
        (uint256 rAmount, , , , ) = _getValues(_WAD);
        if (fromAddressData.isExcluded) {
            fromAddressData.tOwned -= _WAD;
        }
        if (toAddressData.isExcluded) {
            toAddressData.tOwned += _WAD;
        }
        fromAddressData.rOwned -= rAmount;
        fromAddressData.balance -= uint96(_WAD);

        unchecked {
            toAddressData.balance += uint96(_WAD);
            toAddressData.rOwned += rAmount;

            _set(
                $.oo,
                _ownershipIndex(id),
                _registerAndResolveAlias(toAddressData, to)
            );
            delete $.tokenApprovals[id];

            uint256 updatedId = _get(
                $.owned[from],
                --fromAddressData.ownedLength
            );
            _set($.owned[from], _get($.oo, _ownedIndex(id)), uint32(updatedId));

            uint256 n = toAddressData.ownedLength++;
            _set($.oo, _ownedIndex(updatedId), _get($.oo, _ownedIndex(id)));
            _set($.owned[to], n, uint32(id));
            _set($.oo, _ownedIndex(id), uint32(n));
        }
    
        emit Transfer(from, to, _WAD);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                 DATA HITCHHIKING FUNCTIONS                 */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Returns the auxiliary data for `owner`.
    /// Minting, transferring, burning the tokens of `owner` will not change the auxiliary data.
    /// Auxiliary data can be set for any address, even if it does not have any tokens.
    function _getAux(address owner) internal view virtual returns (uint88) {
        return _getDN404Storage().addressData[owner].aux;
    }

    /// @dev Set the auxiliary data for `owner` to `value`.
    /// Minting, transferring, burning the tokens of `owner` will not change the auxiliary data.
    /// Auxiliary data can be set for any address, even if it does not have any tokens.
    function _setAux(address owner, uint88 value) internal virtual {
        _getDN404Storage().addressData[owner].aux = value;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                     SKIP NFT FUNCTIONS                     */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Returns true if account `a` will skip NFT minting on token mints and transfers.
    /// Returns false if account `a` will mint NFTs on token mints and transfers.
    function getSkipNFT(address a) public view virtual returns (bool) {
        AddressData storage d = _getDN404Storage().addressData[a];
        if (d.flags & _ADDRESS_DATA_INITIALIZED_FLAG == 0) return _hasCode(a);
        return d.flags & _ADDRESS_DATA_SKIP_NFT_FLAG != 0;
    }

    /// @dev Sets the caller's skipNFT flag to `skipNFT`
    ///
    /// Emits a {SkipNFTSet} event.
    function setSkipNFT(bool skipNFT) public virtual {
        _setSkipNFT(msg.sender, skipNFT);
    }

    /// @dev Internal function to set account `a` skipNFT flag to `state`
    ///
    /// Initializes account `a` AddressData if it is not currently initialized.
    ///
    /// Emits a {SkipNFTSet} event.
    function _setSkipNFT(address a, bool state) internal virtual {
        AddressData storage d = _addressData(a);
        if ((d.flags & _ADDRESS_DATA_SKIP_NFT_FLAG != 0) != state) {
            d.flags ^= _ADDRESS_DATA_SKIP_NFT_FLAG;
        }
        emit SkipNFTSet(a, state);
    }

    /// @dev Returns a storage data pointer for account `a` AddressData
    ///
    /// Initializes account `a` AddressData if it is not currently initialized.
    function _addressData(
        address a
    ) internal virtual returns (AddressData storage d) {
        DN404Storage storage $ = _getDN404Storage();
        d = $.addressData[a];

        if (d.flags & _ADDRESS_DATA_INITIALIZED_FLAG == 0) {
            uint8 flags = _ADDRESS_DATA_INITIALIZED_FLAG;
            if (_hasCode(a)) flags |= _ADDRESS_DATA_SKIP_NFT_FLAG;
            d.flags = flags;
        }
    }

    /// @dev Returns the `addressAlias` of account `to`.
    ///
    /// Assigns and registers the next alias if `to` alias was not previously registered.
    function _registerAndResolveAlias(
        AddressData storage toAddressData,
        address to
    ) internal virtual returns (uint32 addressAlias) {
        DN404Storage storage $ = _getDN404Storage();
        addressAlias = toAddressData.addressAlias;
        if (addressAlias == 0) {
            addressAlias = ++$.numAliases;
            toAddressData.addressAlias = addressAlias;
            $.aliasToAddress[addressAlias] = to;
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                     MIRROR OPERATIONS                      */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Returns the address of the mirror NFT contract.
    function mirrorERC721() public view virtual returns (address) {
        return _getDN404Storage().mirrorERC721;
    }

    /// @dev Returns the total NFT supply.
    function _totalNFTSupply() internal view virtual returns (uint256) {
        return _getDN404Storage().totalNFTSupply;
    }

    /// @dev Returns `owner` NFT balance.
    function _balanceOfNFT(
        address owner
    ) internal view virtual returns (uint256) {
        return _getDN404Storage().addressData[owner].ownedLength;
    }

    /// @dev Returns the owner of token `id`.
    /// Returns the zero address instead of reverting if the token does not exist.
    function _ownerAt(uint256 id) internal view virtual returns (address) {
        DN404Storage storage $ = _getDN404Storage();
        return $.aliasToAddress[_get($.oo, _ownershipIndex(id))];
    }

    /// @dev Returns the owner of token `id`.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function _ownerOf(uint256 id) internal view virtual returns (address) {
        if (!_exists(id)) revert TokenDoesNotExist();
        return _ownerAt(id);
    }

    /// @dev Returns if token `id` exists.
    function _exists(uint256 id) internal view virtual returns (bool) {
        return _ownerAt(id) != address(0);
    }

    /// @dev Returns the account approved to manage token `id`.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function _getApproved(uint256 id) internal view virtual returns (address) {
        if (!_exists(id)) revert TokenDoesNotExist();
        return _getDN404Storage().tokenApprovals[id];
    }

    /// @dev Sets `spender` as the approved account to manage token `id`, using `msgSender`.
    ///
    /// Requirements:
    /// - `msgSender` must be the owner or an approved operator for the token owner.
    function _approveNFT(
        address spender,
        uint256 id,
        address msgSender
    ) internal virtual returns (address) {
        DN404Storage storage $ = _getDN404Storage();

        address owner = $.aliasToAddress[_get($.oo, _ownershipIndex(id))];

        if (msgSender != owner) {
            if (!$.operatorApprovals[owner][msgSender]) {
                revert ApprovalCallerNotOwnerNorApproved();
            }
        }

        $.tokenApprovals[id] = spender;

        return owner;
    }

    /// @dev Approve or remove the `operator` as an operator for `msgSender`,
    /// without authorization checks.
    function _setApprovalForAll(
        address operator,
        bool approved,
        address msgSender
    ) internal virtual {
        _getDN404Storage().operatorApprovals[msgSender][operator] = approved;
    }

    /// @dev Calls the mirror contract to link it to this contract.
    ///
    /// Reverts if the call to the mirror contract reverts.
    function _linkMirrorContract(address mirror) internal virtual {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x0f4599e5) // `linkMirrorContract(address)`.
            mstore(0x20, caller())
            if iszero(
                and(
                    eq(mload(0x00), 1),
                    call(gas(), mirror, 0, 0x1c, 0x24, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0xd125259c) // `LinkMirrorContractFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Fallback modifier to dispatch calls from the mirror NFT contract
    /// to internal functions in this contract.
    modifier dn404Fallback() virtual {
        DN404Storage storage $ = _getDN404Storage();

        uint256 fnSelector = _calldataload(0x00) >> 224;

        // `isApprovedForAll(address,address)`.
        if (fnSelector == 0xe985e9c5) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x44) revert();

            address owner = address(uint160(_calldataload(0x04)));
            address operator = address(uint160(_calldataload(0x24)));

            _return($.operatorApprovals[owner][operator] ? 1 : 0);
        }
        // `ownerOf(uint256)`.
        if (fnSelector == 0x6352211e) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            uint256 id = _calldataload(0x04);

            _return(uint160(_ownerOf(id)));
        }
        // `transferFromNFT(address,address,uint256,address)`.
        if (fnSelector == 0xe5eb36c8) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x84) revert();

            address from = address(uint160(_calldataload(0x04)));
            address to = address(uint160(_calldataload(0x24)));
            uint256 id = _calldataload(0x44);
            address msgSender = address(uint160(_calldataload(0x64)));

            _transferFromNFT(from, to, id, msgSender);
            _return(1);
        }
        // `setApprovalForAll(address,bool,address)`.
        if (fnSelector == 0x813500fc) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x64) revert();

            address spender = address(uint160(_calldataload(0x04)));
            bool status = _calldataload(0x24) != 0;
            address msgSender = address(uint160(_calldataload(0x44)));

            _setApprovalForAll(spender, status, msgSender);
            _return(1);
        }
        // `approveNFT(address,uint256,address)`.
        if (fnSelector == 0xd10b6e0c) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x64) revert();

            address spender = address(uint160(_calldataload(0x04)));
            uint256 id = _calldataload(0x24);
            address msgSender = address(uint160(_calldataload(0x44)));

            _return(uint160(_approveNFT(spender, id, msgSender)));
        }
        // `getApproved(uint256)`.
        if (fnSelector == 0x081812fc) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            uint256 id = _calldataload(0x04);

            _return(uint160(_getApproved(id)));
        }
        // `balanceOfNFT(address)`.
        if (fnSelector == 0xf5b100ea) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            address owner = address(uint160(_calldataload(0x04)));

            _return(_balanceOfNFT(owner));
        }
        // `totalNFTSupply()`.
        if (fnSelector == 0xe2c79281) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x04) revert();

            _return(_totalNFTSupply());
        }
        // `implementsDN404()`.
        if (fnSelector == 0xb7a94eb8) {
            _return(1);
        }
        _;
    }

    /// @dev Fallback function for calls from mirror NFT contract.
    fallback() external payable virtual dn404Fallback {}

    receive() external payable virtual {}

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                      PRIVATE HELPERS                       */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Struct containing packed log data for `Transfer` events to be
    /// emitted by the mirror NFT contract.
    struct _PackedLogs {
        uint256[] logs;
        uint256 offset;
    }

    /// @dev Initiates memory allocation for packed logs with `n` log items.
    function _packedLogsMalloc(
        uint256 n
    ) private pure returns (_PackedLogs memory p) {
        /// @solidity memory-safe-assembly
        assembly {
            let logs := add(mload(0x40), 0x40) // Offset by 2 words for `_packedLogsSend`.
            mstore(logs, n)
            let offset := add(0x20, logs)
            mstore(0x40, add(offset, shl(5, n)))
            mstore(p, logs)
            mstore(add(0x20, p), offset)
        }
    }

    /// @dev Adds a packed log item to `p` with address `a`, token `id` and burn flag `burnBit`.
    function _packedLogsAppend(
        _PackedLogs memory p,
        address a,
        uint256 id,
        uint256 burnBit
    ) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            let offset := mload(add(0x20, p))
            mstore(offset, or(or(shl(96, a), shl(8, id)), burnBit))
            mstore(add(0x20, p), add(offset, 0x20))
        }
    }

    /// @dev Calls the `mirror` NFT contract to emit Transfer events for packed logs `p`.
    function _packedLogsSend(_PackedLogs memory p, address mirror) private {
        /// @solidity memory-safe-assembly
        assembly {
            let logs := mload(p)
            let o := sub(logs, 0x40) // Start of calldata to send.
            mstore(o, 0x263c69d6) // `logTransfer(uint256[])`.
            mstore(add(o, 0x20), 0x20) // Offset of `logs` in the calldata to send.
            let n := add(0x44, shl(5, mload(logs))) // Length of calldata to send.
            if iszero(
                and(
                    eq(mload(o), 1),
                    call(gas(), mirror, 0, add(o, 0x1c), n, o, 0x20)
                )
            ) {
                revert(o, 0x00)
            }
        }
    }

    /// @dev Struct of temporary variables for transfers.
    struct _TransferTemps {
        uint256 nftAmountToBurn;
        uint256 nftAmountToMint;
        uint256 fromBalance;
        uint256 toBalance;
        uint256 fromOwnedLength;
        uint256 toOwnedLength;
        uint256 rOwnedFrom;
        uint256 rOwnedTo;
        uint256 tOwnedFrom;
        uint256 tOwnedTo;
    }

    /// @dev Returns if `a` has bytecode of non-zero length.
    function _hasCode(address a) private view returns (bool result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := extcodesize(a) // Can handle dirty upper bits.
        }
    }

    /// @dev Returns the calldata value at `offset`.
    function _calldataload(
        uint256 offset
    ) private pure returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := calldataload(offset)
        }
    }

    /// @dev Executes a return opcode to return `x` and end the current call frame.
    function _return(uint256 x) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, x)
            return(0x00, 0x20)
        }
    }

    /// @dev Returns `max(0, x - y)`.
    function _zeroFloorSub(
        uint256 x,
        uint256 y
    ) private pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := mul(gt(x, y), sub(x, y))
        }
    }

    /// @dev Returns `i << 1`.
    function _ownershipIndex(uint256 i) private pure returns (uint256) {
        return i << 1;
    }

    /// @dev Returns `(i << 1) + 1`.
    function _ownedIndex(uint256 i) private pure returns (uint256) {
        unchecked {
            return (i << 1) + 1;
        }
    }

    /// @dev Returns the uint32 value at `index` in `map`.
    function _get(
        Uint32Map storage map,
        uint256 index
    ) private view returns (uint32 result) {
        result = uint32(map.map[index >> 3] >> ((index & 7) << 5));
    }

    /// @dev Updates the uint32 value at `index` in `map`.
    function _set(Uint32Map storage map, uint256 index, uint32 value) private {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, map.slot)
            mstore(0x00, shr(3, index))
            let s := keccak256(0x00, 0x40) // Storage slot.
            let o := shl(5, and(index, 7)) // Storage slot offset (bits).
            let v := sload(s) // Storage slot value.
            let m := 0xffffffff // Value mask.
            sstore(s, xor(v, shl(o, and(m, xor(shr(o, v), value)))))
        }
    }

    /// @dev Sets the owner alias and the owned index together.
    function _setOwnerAliasAndOwnedIndex(
        Uint32Map storage map,
        uint256 id,
        uint32 ownership,
        uint32 ownedIndex
    ) private {
        /// @solidity memory-safe-assembly
        assembly {
            let value := or(shl(32, ownedIndex), and(0xffffffff, ownership))
            mstore(0x20, map.slot)
            mstore(0x00, shr(2, id))
            let s := keccak256(0x00, 0x40) // Storage slot.
            let o := shl(6, and(id, 3)) // Storage slot offset (bits).
            let v := sload(s) // Storage slot value.
            let m := 0xffffffffffffffff // Value mask.
            sstore(s, xor(v, shl(o, and(m, xor(shr(o, v), value)))))
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*              PRIVATE FUNCTIONS FOR REFLECTIONS             */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Reflects fee to all holders
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        DN404Storage storage $ = _getDN404Storage();
        $.rTotal = $.rTotal - rFee;
        $.tFeeTotal = $.tFeeTotal + tFee;
    }

    function _getValues(
        uint256 tAmount
    ) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee) = _getTValues(tAmount);
        uint256 currentRate = _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(
            tAmount,
            tFee,
            currentRate
        );
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee);
    }

    function _getTValues(
        uint256 tAmount
    ) private view returns (uint256, uint256) {
        uint256 tFee = _calculateTaxFee(tAmount);
        uint256 tTransferAmount = tAmount - tFee;
        return (tTransferAmount, tFee);
    }

    function _getRValues(
        uint256 tAmount,
        uint256 tFee,
        uint256 currentRate
    ) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rTransferAmount = rAmount - rFee;
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return (rSupply / tSupply);
    }

    /// @dev returns current supply in terms of 'r' and 't'
    function _getCurrentSupply() private view returns (uint256, uint256) {
        DN404Storage storage $ = _getDN404Storage();
        uint256 rSupply = $.rTotal;
        uint256 tSupply = $.tTotal;
        for (uint256 i = 0; i < $.excluded.length; i++) {
            AddressData storage excludedAddressData = $.addressData[
                $.excluded[i]
            ];

            if (
                excludedAddressData.rOwned > rSupply ||
                excludedAddressData.tOwned > tSupply
            ) return ($.rTotal, $.tTotal);
            rSupply = rSupply - excludedAddressData.rOwned;
            tSupply = tSupply - excludedAddressData.tOwned;
        }
        if (rSupply < $.rTotal / $.tTotal) return ($.rTotal, $.tTotal);
        return (rSupply, tSupply);
    }

    /// @dev returns the total reflected tokens
    function getTotalReflections() public view returns (uint256) {
        return _getDN404Storage().tFeeTotal;
    }

    function _calculateTaxFee(uint256 amount) private view returns (uint256) {
        return (amount * _getDN404Storage().taxFee) / (10 ** 3);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                     ACCESS FUNCTIONS                       */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/
}
