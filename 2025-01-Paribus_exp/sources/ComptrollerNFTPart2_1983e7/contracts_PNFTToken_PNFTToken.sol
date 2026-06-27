// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "../Comptroller/ComptrollerInterfaces.sol";
import "./PNFTTokenInterfaces.sol";
import "../PToken/PTokenInterfaces.sol";
import "../PriceOracle/PriceOracleInterfaces.sol";
import "openzeppelin2/token/ERC20/SafeERC20.sol";
import "openzeppelin2/token/ERC721/IERC721Receiver.sol";
import "../Utils/ExponentialNoError.sol";
import "../Interfaces/NFTXInterfaces.sol";
import "../Interfaces/SudoswapInterfaces.sol";
import "../Interfaces/UniswapV3Interfaces.sol";

/**
 * @title Paribus PNFTToken Contract
 * @notice Abstract base for PNFTTokens
 * @author Paribus
 */
contract PNFTToken is PNFTTokenInterface, ExponentialNoError {
    using SafeERC20 for IERC20;

    /**
     * @notice Initialize the money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param name_ EIP-721 name of this token
     * @param symbol_ EIP-721 symbol of this token
     */
    function initialize(address underlying_,
        address comptroller_,
        string memory name_,
        string memory symbol_) public {
        require(msg.sender == admin, "only admin may initialize the market");
        require(underlying_ != address(0), "invalid argument");
        require(underlying == address(0), "can only initialize once");

        // Set the comptroller
        _setComptroller(comptroller_);

        name = name_;
        symbol = symbol_;
        underlying = underlying_;
        NFTXioVaultId = -1; // -1 == not set

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    /*** ERC165 Functions ***/

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == 0x80ac58cd || // _INTERFACE_ID_ERC721
               interfaceId == 0x01ffc9a7 || // _INTERFACE_ID_ERC165
               interfaceId == 0x780e9d63;   // _INTERFACE_ID_ERC721_ENUMERABLE
    }

    /*** EIP721 Functions ***/

    /**
     * @dev Returns whether `tokenId` exists.
     *
     * Tokens can be managed by their owner or approved accounts via {approve} or {setApprovalForAll}.
     *
     * Tokens start existing when they are minted (`_mint`),
     * and stop existing when they are burned (`_burn`).
     */
    function _exists(uint tokenId) internal view returns (bool) {
        return tokensOwners[tokenId] != address(0);
    }

    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.
        uint size;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    /**
     * @dev Internal function to invoke {IERC721Receiver-onERC721Received} on a target address.
     * The call is not executed if the target address is not a contract.
     *
     * @param from address representing the previous owner of the given token ID
     * @param to target address that will receive the tokens
     * @param tokenId The token ID
     * @param _data bytes optional data to send along with the call
     * @return bool whether the call correctly returned the expected magic value
     */
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory _data) internal returns (bool) {
        if (!isContract(to))
            return true;

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = to.call(abi.encodeWithSelector(
                IERC721Receiver(to).onERC721Received.selector,
                msg.sender,
                from,
                tokenId,
                _data
            ));

        if (!success) {
            if (returndata.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert("transfer to non ERC721Receiver implementer");
            }
        } else {
            bytes4 retval = abi.decode(returndata, (bytes4));
            bytes4 _ERC721_RECEIVED = 0x150b7a02; // Equals to `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
            return (retval == _ERC721_RECEIVED);
        }

    }

    /**
     * @dev Gets the list of token IDs of the requested owner.
     * @param owner address owning the tokens
     * @return uint[] List of token IDs owned by the requested address
     */
    function _tokensOfOwner(address owner) internal view returns (uint[] storage) {
        return ownedTokens[owner];
    }

    /**
     * @dev Private function to add a token to this extension's ownership-tracking data structures.
     * @param to address representing the new owner of the given token ID
     * @param tokenId uint ID of the token to be added to the tokens list of the given address
     */
    function _addTokenToOwnerEnumeration(address to, uint tokenId) internal {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
    }

    /**
     * @dev Private function to add a token to this extension's token tracking data structures.
     * @param tokenId uint ID of the token to be added to the tokens list
     */
    function _addTokenToAllTokensEnumeration(uint tokenId) internal {
        allTokensIndex[tokenId] = allTokens.length;
        allTokens.push(tokenId);
    }

    /**
     * @dev Private function to remove a token from this extension's ownership-tracking data structures. Note that
     * while the token is not assigned a new owner, the ownedTokensIndex mapping is _not_ updated: this allows for
     * gas optimizations e.g. when performing a transfer operation (avoiding double writes).
     * This has O(1) time complexity, but alters the order of the ownedTokens array.
     * @param from address representing the previous owner of the given token ID
     * @param tokenId uint ID of the token to be removed from the tokens list of the given address
     */
    function _removeTokenFromOwnerEnumeration(address from, uint tokenId) internal {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint lastTokenIndex = sub_(ownedTokens[from].length, 1);
        uint tokenIndex = ownedTokensIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint lastTokenId = ownedTokens[from][lastTokenIndex];

            ownedTokens[from][tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
            ownedTokensIndex[lastTokenId] = tokenIndex; // Update the moved token's index
        }

        // This also deletes the contents at the last position of the array
        ownedTokens[from].length--;

        // Note that ownedTokensIndex[tokenId] hasn't been cleared: it still points to the old slot (now occupied by
        // lastTokenId, or just over the end of the array if the token was the last one).
    }

    /**
     * @dev Private function to remove a token from this extension's token tracking data structures.
     * This has O(1) time complexity, but alters the order of the allTokens array.
     * @param tokenId uint ID of the token to be removed from the tokens list
     */
    function _removeTokenFromAllTokensEnumeration(uint tokenId) internal {
        // To prevent a gap in the tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint lastTokenIndex = sub_(allTokens.length, 1);
        uint tokenIndex = allTokensIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary. However, since this occurs so
        // rarely (when the last minted token is burnt) that we still do the swap here to avoid the gas cost of adding
        // an 'if' statement (like in _removeTokenFromOwnerEnumeration)
        uint lastTokenId = allTokens[lastTokenIndex];

        allTokens[tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
        allTokensIndex[lastTokenId] = tokenIndex; // Update the moved token's index

        // This also deletes the contents at the last position of the array
        allTokens.length--;
        allTokensIndex[tokenId] = 0;
    }

    /**
     * @notice Transfer `tokens` tokens from `src` to `dst`
     * @dev Called by both `transfer` and `safeTransferInternal` internally
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokenId The token ID
     */
    function transferInternal(address src, address dst, uint tokenId) internal {
        require(ownerOf(tokenId) == src, "transfer from incorrect owner");
        require(dst != address(0), "transfer to the zero address");

        // Fail if transfer not allowed
        Error allowed = comptroller.transferNFTAllowed(address(this), src, dst, tokenId);
        require(allowed == Error.NO_ERROR, "transfer comptroller rejection");

        // Do the calculations, checking for {under,over}flow
        uint srcTokensNew = sub_(accountTokens[src], 1);
        uint dstTokensNew = add_(accountTokens[dst], 1);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // Clear approvals from the previous owner
        approveInternal(address(0), tokenId);

        /* Check for self-transfers
         * When src == dst, the values srcTokensNew, dstTokensNew are INCORRECT
         */
        if (src != dst) {
            accountTokens[src] = srcTokensNew;
            accountTokens[dst] = dstTokensNew;

            // Erc721Enumerable
            _removeTokenFromOwnerEnumeration(src, tokenId);
            _addTokenToOwnerEnumeration(dst, tokenId);
        }

        tokensOwners[tokenId] = dst;

        // We emit a Transfer event
        emit Transfer(src, dst, tokenId);

        // We call the defense hook
        comptroller.transferNFTVerify(address(this), src, dst, tokenId);
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param tokenId The token ID
     */
    function transferFrom(address src, address dst, uint tokenId) external nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "transfer caller is not owner nor approved");
        transferInternal(src, dst, tokenId);
    }

    /**
     * @dev Safely transfers `tokenId` token from `src` to `dst`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `src` cannot be the zero address.
     * - `dst` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `src`.
     * - If the caller is not `src`, it must have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `dst` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address src, address dst, uint tokenId) public {
        safeTransferFrom(src, dst, tokenId, "");
    }

    /**
     * @dev Safely transfers `tokenId` token from `src` to `dst`.
     *
     * Requirements:
     *
     * - `src` cannot be the zero address.
     * - `dst` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `src`.
     * - If the caller is not `src`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `dst` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(address src, address dst, uint tokenId, bytes memory data) public nonReentrant {
        require(_isApprovedOrOwner(msg.sender, tokenId), "transfer caller is not owner nor approved");
        safeTransferInternal(src, dst, tokenId, data);
    }

    /**
     * @dev Safely transfers `tokenId` token from `src` to `dst`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * `data` is additional data, it has no specified format and it is sent in call to `dst`.
     *
     * This internal function is equivalent to {safeTransferFrom}, and can be used to e.g.
     * implement alternative mechanisms to perform token transfer, such as signature-based.
     *
     * Requirements:
     *
     * - `src` cannot be the zero address.
     * - `dst` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `src`.
     * - If `dst` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferInternal(address src, address dst, uint tokenId, bytes memory data) internal {
        transferInternal(src, dst, tokenId);
        require(_checkOnERC721Received(src, dst, tokenId, data), "transfer to non ERC721Receiver implementer");
    }

    /// @dev Returns whether `spender` is allowed to manage `tokenId`.
    function _isApprovedOrOwner(address spender, uint tokenId) internal view returns (bool) {
        require(_exists(tokenId), "operator query for nonexistent token");
        address owner = ownerOf(tokenId);
        return (spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender);
    }

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint tokenId) external {
        address owner = ownerOf(tokenId);
        require(to != owner, "approval to current owner");

        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "approve caller is not owner nor approved for all");

        approveInternal(to, tokenId);
    }

    function approveInternal(address to, uint tokenId) internal {
        transferAllowances[tokenId] = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint tokenId) public view returns (address) {
        require(_exists(tokenId), "approved query for nonexistent token");
        return transferAllowances[tokenId];
    }

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool approved) public {
        setApprovalForAllInternal(msg.sender, operator, approved);
    }

    /**
     * @dev Approve `operator` to operate on all of `owner` tokens
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAllInternal(address owner, address operator, bool approved) internal {
        require(owner != operator, "approve to caller");
        operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return operatorApprovals[owner][operator];
    }

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint) {
        require(owner != address(0), "address zero is not a valid owner");
        return accountTokens[owner];
    }

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint tokenId) public view returns (address) {
        address owner = tokensOwners[tokenId];
        require(owner != address(0), "owner query for nonexistent token");
        return owner;
    }

    /**
     * @dev Gets the token ID at a given index of the tokens list of the requested owner.
     * @param owner address owning the tokens list to be accessed
     * @param index uint representing the index to be accessed of the requested tokens list
     * @return uint token ID at the given index of the tokens list owned by the requested address
     */
    function tokenOfOwnerByIndex(address owner, uint index) external view returns (uint) {
        require(index < this.balanceOf(owner), "owner index out of bounds");
        return ownedTokens[owner][index];
    }

    /**
     * @dev Gets the total amount of tokens stored by the contract.
     * @return uint representing the total amount of tokens
     */
    function totalSupply() public view returns (uint) {
        return allTokens.length;
    }

    /**
     * @dev Gets the token ID at a given index of all the tokens in this contract
     * Reverts if the index is greater or equal to the total number of tokens.
     * @param index uint representing the index to be accessed of the tokens list
     * @return uint token ID at the given index of the tokens list
     */
    function tokenByIndex(uint index) public view returns (uint) {
        require(index < totalSupply(), "global index out of bounds");
        return allTokens[index];
    }

    /**
    * @dev Gets the token IDs owned by the owner
    * @param _owner owner of the token ids
    * @return uint[] token IDs owned by the requested address
    */
    function tokenOfOwner(address _owner) public view returns(uint[] memory) {
        return _tokensOfOwner(_owner);
    }

    /*** User Interface ***/

    /**
     * @notice Get the underlying balance of the `owner`
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(address owner) external view returns (uint) {
        return accountTokens[owner];
    }

    /**
     * @notice Get cash balance of this pToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Sender supplies assets into the market and receives pTokens in exchange
     * @param tokenId The token ID
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint tokenId) external returns (Error) {
        return mintInternal(msg.sender, tokenId);
    }

    function safeMint(uint tokenId) external returns (Error) {
        return safeMintInternal(tokenId, "");
    }

    function safeMint(uint tokenId, bytes calldata data) external returns (Error) {
        return safeMintInternal(tokenId, data);
    }

    function safeMintInternal(uint tokenId, bytes memory data) internal returns (Error) {
        require(_checkOnERC721Received(address(0), msg.sender, tokenId, data), "transfer to non ERC721Receiver implementer");
        return mintInternal(msg.sender, tokenId);
    }

    /**
     * @notice Sender supplies assets into the market and receives pTokens in exchange
     * @param minter The address of the account which is supplying the assets
     * @param tokenId The token ID
     * @return Error 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mintInternal(address minter, uint tokenId) internal nonReentrant returns (Error) {
        require(!_exists(tokenId), "token already minted");

        // Fail if mint not allowed
        Error allowed = comptroller.mintNFTAllowed(address(this), minter, tokenId);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        /*
         * We calculate the new total supply of pTokens and minter token balance, checking for overflow:
         *  accountTokensNew = accountTokens[minter] + 1
         */

        uint accountTokensNew = add_(accountTokens[minter], 1);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        doTransferIn(minter, tokenId);

        // Erc721Enumerable
        _addTokenToOwnerEnumeration(minter, tokenId);
        _addTokenToAllTokensEnumeration(tokenId);

        // We write previously calculated values into storage
        accountTokens[minter] = accountTokensNew;
        tokensOwners[tokenId] = minter;

        // We emit a Mint event, and a Transfer event
        emit Mint(minter, tokenId);
        emit Transfer(address(0), minter, tokenId);

        // We call the defense hook
        comptroller.mintNFTVerify(address(this), minter, tokenId);

        return Error.NO_ERROR;
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @param tokenId The token ID
     */
    function redeem(uint tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "caller is not owner");
        return redeemInternal(tokenId);
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @param tokenId The token ID
     */
    function redeemInternal(uint tokenId) internal nonReentrant {
        address owner = ownerOf(tokenId);

        // Fail if redeem not allowed
        Error allowed = comptroller.redeemNFTAllowed(address(this), owner, tokenId);
        require(allowed == Error.NO_ERROR, "redeem comptroller rejection");

        // Burn PNFTToken
        burnInternal(tokenId);

        // We invoke doTransferOut for the owner
        doTransferOut(owner, tokenId);

        emit Redeem(owner, tokenId);

        // We call the defense hook
        comptroller.redeemNFTVerify(address(this), owner, tokenId);
    }

    function burnInternal(uint tokenId) internal {
        address owner = ownerOf(tokenId);

        /*
         * We calculate the new owner balance, checking for underflow:
         *  accountTokensNew = accountTokens[owner] - 1
         */

        uint accountTokensNew = sub_(accountTokens[owner], 1);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // Clear approvals from the previous owner
        approveInternal(address(0), tokenId);

        // Erc721Enumerable
        _removeTokenFromOwnerEnumeration(owner, tokenId);
        ownedTokensIndex[tokenId] = 0;
        _removeTokenFromAllTokensEnumeration(tokenId);

        // We write previously calculated values into storage
        accountTokens[owner] = accountTokensNew;
        tokensOwners[tokenId] = address(0);

        // We emit a Transfer event, and a Redeem event
        emit Transfer(owner, address(0), tokenId);
    }

    /*** Liquidation ***/

    function liquidateCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (Error) {
        return liquidateCollateralInternal(msg.sender, borrower, tokenId, NFTLiquidationExchangePTokenAddress, false);
    }

    function liquidateSeizeCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (Error) {
        return liquidateCollateralInternal(msg.sender, borrower, tokenId, NFTLiquidationExchangePTokenAddress, true);
    }

    function liquidateCollateralInternal(address liquidator, address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress, bool isLiquidatorSeize) internal nonReentrant returns (Error) {
        require(ownerOf(tokenId) == borrower, "incorrect borrower");
        require(borrower != liquidator, "invalid account pair");

        // Fail if liquidateCollateral not allowed
        Error allowed = comptroller.liquidateNFTCollateralAllowed(address(this), liquidator, borrower, tokenId, NFTLiquidationExchangePTokenAddress);
        if (allowed != Error.NO_ERROR) {
            return fail(allowed);
        }

        // double-check...
        (, , uint beforeLiquidityShortfall) = comptroller.getAccountLiquidity(borrower);

        // liquidate collateral
        liquidateCollateralInternalImpl(liquidator, borrower, tokenId, PErc20Interface(NFTLiquidationExchangePTokenAddress), isLiquidatorSeize);

        // ...double-check
        (, , uint liquidityShortfall) = comptroller.getAccountLiquidity(borrower);
        // sanity check
        require(beforeLiquidityShortfall >= liquidityShortfall, "invalid liquidity after the exchange");

        // We emit a LiquidateCollateral event
        emit LiquidateCollateral(liquidator, borrower, tokenId, NFTLiquidationExchangePTokenAddress);

        // We call the defense hook
        comptroller.liquidateNFTCollateralVerify(address(this), liquidator, borrower, tokenId);

        return Error.NO_ERROR;
    }

    function liquidateCollateralInternalImpl(address liquidator, address borrower, uint tokenId, PErc20Interface NFTLiquidationExchangePToken, bool isLiquidatorSeize) internal {
        (uint minAmountToReceiveOnExchange, uint liquidationIncentive, uint pbxBonusIncentive,  uint seizeValueToReceive) = comptroller.nftLiquidateCalculateValues(address(this), tokenId, address(NFTLiquidationExchangePToken));

        if (isLiquidatorSeize) { // sell underlying NFT to liquidator
            require(seizeValueToReceive > 0, "NFT seize liquidation not configured");
            _exchangeUnderlying(borrower, tokenId, seizeValueToReceive, liquidationIncentive, liquidator, true, NFTLiquidationExchangePToken);
        } else { // exchange underlying NFT for NFTLiquidationExchangePToken
            assert(minAmountToReceiveOnExchange > 0);
            _exchangeUnderlying(borrower, tokenId, minAmountToReceiveOnExchange, liquidationIncentive, liquidator, false, NFTLiquidationExchangePToken);
        }

        // send liquidation incentive
        // approve already called in _exchangeUnderlying
        if (liquidationIncentive > 0) {
            uint exchangePTokenBalanceBefore = NFTLiquidationExchangePToken.balanceOf(address(this));
            require(NFTLiquidationExchangePToken.mint(liquidationIncentive) == Error.NO_ERROR, "NFTLiquidationExchangePToken mint incentive failed");
            require(NFTLiquidationExchangePToken.transfer(liquidator, NFTLiquidationExchangePToken.balanceOf(address(this)) - exchangePTokenBalanceBefore), "NFTLiquidationExchangePToken transfer incentive failed");
        }

        // send PBX bonus liquidation incentive
        comptroller.nftLiquidateSendPBXBonusIncentive(pbxBonusIncentive, liquidator);
    }

    /// @dev Exchange underlying NFT token for NFTLiquidationExchangePToken within owner's collateral
    function _exchangeUnderlying(address owner, uint tokenId, uint minAmountToReceive, uint liquidationIncentive, address liquidator, bool isLiquidatorSeize, PErc20Interface NFTLiquidationExchangePToken) internal {
        assert(ownerOf(tokenId) == owner);
        assert(minAmountToReceive > 0);
        // sanity check
        require(minAmountToReceive > liquidationIncentive, "liquidateCollateral not possible");

        IERC20 NFTLiquidationExchangeToken = IERC20(NFTLiquidationExchangePToken.underlying());
        uint exchangeTokenBalanceBefore = NFTLiquidationExchangeToken.balanceOf(address(this));

        // burn pNFTToken
        burnInternal(tokenId);

        if (isLiquidatorSeize) { // sell underlying NFT to liquidator
            _sellUnderlyingToLiquidator(tokenId, minAmountToReceive, liquidator, address(NFTLiquidationExchangeToken));

        } else { // exchange underlying NFT for NFTLiquidationExchangePToken
            if (comptroller.NFTXioMarketplaceZapAddress() != address(0) && NFTXioVaultId >= 0) { // NFTXio liquidation set
                _sellUnderlyingOnNFTXio(tokenId, minAmountToReceive, address(NFTLiquidationExchangeToken));

            } else {
                require(comptroller.sudoswapRouterAddress() != address(0) && sudoswapLSSVMPairAddress != address(0) && // sudoswap liquidation set
                        comptroller.uniswapV3SwapRouterAddress() != address(0), "NFT liquidation not configured");

                uint ethAmountReceived = _sellUnderlyingOnSudoswapForETH(tokenId, 0);
                _exchangeEthForTokensOnUniswap(address(NFTLiquidationExchangeToken), minAmountToReceive, ethAmountReceived);
            }
        }

        // address(this) has NFTLiquidationExchangeToken now
        uint amountReceived = NFTLiquidationExchangeToken.balanceOf(address(this)) - exchangeTokenBalanceBefore;
        require(amountReceived >= minAmountToReceive, "incorrect amount received");

        // exchange NFTLiquidationExchangeToken for its PToken
        NFTLiquidationExchangeToken.safeApprove(address(NFTLiquidationExchangePToken), 0);
        NFTLiquidationExchangeToken.safeApprove(address(NFTLiquidationExchangePToken), amountReceived);
        uint exchangePTokenBalanceBefore = NFTLiquidationExchangePToken.balanceOf(address(this));
        require(NFTLiquidationExchangePToken.mint(amountReceived - liquidationIncentive) == Error.NO_ERROR, "NFTLiquidationExchangePToken mint failed");

        // transfer NFTLiquidationExchangePToken to owner's collateral
        require(NFTLiquidationExchangePToken.transfer(owner, NFTLiquidationExchangePToken.balanceOf(address(this)) - exchangePTokenBalanceBefore), "NFTLiquidationExchangePToken transfer to owner failed");
    }

    function _concatBytes(bytes memory a, bytes memory b) internal pure returns (bytes memory c) {
        uint alen = a.length;
        uint totallen = alen + b.length;
        uint loopsa = (a.length + 31) / 32;
        uint loopsb = (b.length + 31) / 32;

        assembly {
            let m := mload(0x40)
            mstore(m, totallen)
            for {  let i := 0 } lt(i, loopsa) { i := add(1, i) } { mstore(add(m, mul(32, add(1, i))), mload(add(a, mul(32, add(1, i))))) }
            for {  let i := 0 } lt(i, loopsb) { i := add(1, i) } { mstore(add(m, add(mul(32, add(1, i)), alen)), mload(add(b, mul(32, add(1, i))))) }
            mstore(0x40, add(m, add(32, totallen)))
            c := m
        }
    }

    function _callSudoswapSwap(uint tokenId, uint minAmountETHToReceive) internal {
        bytes memory encodedSig = abi.encodePacked(
            bytes4(0xec72bc65),               // swap function signature
            _concatBytes(                     // function arguments
                abi.encodePacked(uint256(32),
                                 uint256(160),
                                 uint256(192),
                                 uint256(address(this)), // tokenRecipient
                                 uint256(address(this)), // nftRecipient
                                 uint256(0),  // recycleEth
                                 uint256(0),
                                 uint256(1),
                                 uint256(32),
                                 uint256(sudoswapLSSVMPairAddress), // pair
                                 uint256(1),  // isETHSell
                                 uint256(1)), // isERC721
                abi.encodePacked(uint256(288),
                                 uint256(0),  // doPropertyCheck
                                 uint256(352),
                                 uint256(0),  // expectedSpotPrice
                                 uint256(minAmountETHToReceive), // minExpectedOutput
                                 uint256(384),
                                 uint256(1),
                                 uint256(tokenId),
                                 uint256(0),
                                 uint256(1),
                                 uint256(minAmountETHToReceive)) // minExpectedOutputPerNumNFTs
            )
        );

        (bool success, bytes memory returnData) = comptroller.sudoswapRouterAddress().call(encodedSig);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
    }

    function _sellUnderlyingOnSudoswapForETH(uint tokenId, uint minAmountETHToReceive) internal returns (uint) {
        uint256 balanceBefore = address(this).balance;

        approveUnderlying(tokenId, comptroller.sudoswapRouterAddress());
        _callSudoswapSwap(tokenId, minAmountETHToReceive);

        uint amountReceived = address(this).balance - balanceBefore;
        require(amountReceived > minAmountETHToReceive, "sudoswap: too little ETH amount received");
        return amountReceived;
    }

    function _exchangeEthForTokensOnUniswap(address assetToReceive, uint minAmountToReceive, uint amountToSell) internal {
        IUniswapV3SwapRouter router = IUniswapV3SwapRouter(comptroller.uniswapV3SwapRouterAddress());

        IUniswapV3SwapRouter.ExactInputSingleParams memory swapParams;
        swapParams.tokenIn = router.WETH9();
        swapParams.tokenOut = assetToReceive;
        swapParams.fee = 500;
        swapParams.recipient = address(this);
        swapParams.deadline = block.timestamp;
        swapParams.amountIn = amountToSell;
        swapParams.amountOutMinimum = minAmountToReceive;
        swapParams.sqrtPriceLimitX96 = 0; // 0 to ensure we swap our exact input amount

        router.exactInputSingle.value(amountToSell)(swapParams);
    }

    function _sellUnderlyingToLiquidator(uint tokenId, uint amountToReceive, address liquidator, address assetToReceive) internal {
        IERC20(assetToReceive).safeTransferFrom(liquidator, address(this), amountToReceive);
        doTransferOut(liquidator, tokenId);
    }

    function _sellUnderlyingOnNFTXio(uint tokenId, uint minAmountToReceive, address assetToReceive) internal {
        INFTXMarketplaceZap NFTXioMarketplace = INFTXMarketplaceZap(comptroller.NFTXioMarketplaceZapAddress());

        // sell underlying for NFTLiquidationExchangeToken
        address[] memory path = new address[](3);
        path[0] = NFTXioMarketplace.nftxFactory().vault(uint(NFTXioVaultId));
        path[1] = NFTXioMarketplace.WETH();
        path[2] = assetToReceive;

        uint[] memory ids = new uint[](1);
        ids[0] = tokenId;

        approveUnderlying(tokenId, address(NFTXioMarketplace));
        NFTXioMarketplace.mintAndSell721WETH(uint(NFTXioVaultId), ids, minAmountToReceive, path, address(this));
    }

    /*** Admin Functions ***/

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      */
    function _setPendingAdmin(address payable newPendingAdmin) external {
        require(msg.sender == admin, "only admin");
        require(newPendingAdmin != address(0), "admin cannot be zero address");

        emit NewPendingAdmin(pendingAdmin, newPendingAdmin);
        pendingAdmin = newPendingAdmin;
    }

    /**
      * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
      * @dev Admin function for pending admin to accept role and update admin
      */
    function _acceptAdmin() external {
        require(msg.sender == pendingAdmin, "only pending admin");

        emit NewAdmin(admin, pendingAdmin);
        emit NewPendingAdmin(pendingAdmin, address(0));
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    /**
      * @notice Sets a new comptroller for the market
      * @dev Admin function to set a new comptroller
      */
    function _setComptroller(address newComptroller) public {
        require(msg.sender == admin, "only admin");
        (bool success, ) = newComptroller.staticcall(abi.encodeWithSignature("isComptroller()"));
        require(success, "not valid comptroller address");

        emit NewComptroller(address(comptroller), newComptroller);
        comptroller = ComptrollerNFTInterface(newComptroller);
    }

    function _setNFTXioVaultId(int newNFTXioVaultId) external {
        require(msg.sender == admin, "only admin");
        require(INFTXVault(INFTXMarketplaceZap(comptroller.NFTXioMarketplaceZapAddress()).nftxFactory().vault(uint(newNFTXioVaultId))).assetAddress() == underlying, "wrong NFTXVaultId");

        NFTXioVaultId = newNFTXioVaultId;
    }

    function _setSudoswapLSSVMPairAddress(address newSudoswapLSSVMPairAddress) external {
        require(msg.sender == admin, "only admin");
        require(SudoswapLSSVMPairETHInterface(newSudoswapLSSVMPairAddress).nft() == underlying, "wrong newSudoswapLSSVMPairAddress.nft()");

        sudoswapLSSVMPairAddress = newSudoswapLSSVMPairAddress;
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() internal view returns (uint);

    function checkIfOwnsUnderlying(uint tokenId) internal view returns (bool);

    function approveUnderlying(uint tokenId, address addr) internal;

    /**
     * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
     *  This may revert due to insufficient balance or insufficient allowance.
     */
    function doTransferIn(address from, uint tokenId) internal;

    /**
     * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
     *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
     *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
     */
    function doTransferOut(address to, uint tokenId) internal;

    /// @dev Prevents a contract from calling itself, directly or indirectly.
    modifier nonReentrant() {
        require(_notEntered, "reentered");
        _notEntered = false;
        _;
        _notEntered = true;
        // get a gas-refund post-Istanbul
    }
}
