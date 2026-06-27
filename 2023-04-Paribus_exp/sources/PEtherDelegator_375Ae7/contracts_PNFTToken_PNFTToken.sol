// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Comptroller/ComptrollerInterfaces.sol";
import "./PNFTTokenInterfaces.sol";
import "../PToken/PTokenInterfaces.sol";
import "../ErrorReporter.sol";
import "../Interfaces/EIP20Interface.sol";
import "../Interfaces/IERC721Receiver.sol";
import "../Utils/ExponentialNoError.sol";
import "../Interfaces/NFTXInterfaces.sol";
import "../Interfaces/SudoswapInterfaces.sol";

/**
 * @title Paribus PNFTToken Contract
 * @notice Abstract base for PNFTTokens
 * @author Paribus
 */
contract PNFTToken is PNFTTokenInterface, ExponentialNoError, TokenErrorReporter {
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

        // Set the comptroller
        _setComptroller(comptroller_);

        name = name_;
        symbol = symbol_;
        underlying = underlying_;

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
    function _exists(uint256 tokenId) internal view returns (bool) {
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
        assembly {size := extcodesize(account)}
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
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory _data) private returns (bool) {
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

        return false; // shut up
    }

    /**
     * @dev Gets the list of token IDs of the requested owner.
     * @param owner address owning the tokens
     * @return uint256[] List of token IDs owned by the requested address
     */
    function _tokensOfOwner(address owner) internal view returns (uint256[] storage) {
        return ownedTokens[owner];
    }

    /**
     * @dev Private function to add a token to this extension's ownership-tracking data structures.
     * @param to address representing the new owner of the given token ID
     * @param tokenId uint256 ID of the token to be added to the tokens list of the given address
     */
    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
    }

    /**
     * @dev Private function to add a token to this extension's token tracking data structures.
     * @param tokenId uint256 ID of the token to be added to the tokens list
     */
    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        allTokensIndex[tokenId] = allTokens.length;
        allTokens.push(tokenId);
    }

    /**
     * @dev Private function to remove a token from this extension's ownership-tracking data structures. Note that
     * while the token is not assigned a new owner, the ownedTokensIndex mapping is _not_ updated: this allows for
     * gas optimizations e.g. when performing a transfer operation (avoiding double writes).
     * This has O(1) time complexity, but alters the order of the ownedTokens array.
     * @param from address representing the previous owner of the given token ID
     * @param tokenId uint256 ID of the token to be removed from the tokens list of the given address
     */
    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastTokenIndex = sub_(ownedTokens[from].length, 1);
        uint256 tokenIndex = ownedTokensIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];

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
     * @param tokenId uint256 ID of the token to be removed from the tokens list
     */
    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        // To prevent a gap in the tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastTokenIndex = sub_(allTokens.length, 1);
        uint256 tokenIndex = allTokensIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary. However, since this occurs so
        // rarely (when the last minted token is burnt) that we still do the swap here to avoid the gas cost of adding
        // an 'if' statement (like in _removeTokenFromOwnerEnumeration)
        uint256 lastTokenId = allTokens[lastTokenIndex];

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
        uint allowed = comptroller.transferNFTAllowed(address(this), src, dst, tokenId);
        require(allowed == 0, "COMPTROLLER_REJECTION: TRANSFER_COMPTROLLER_REJECTION");

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
     * @return Whether or not the transfer succeeded
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
    function safeTransferFrom(address src, address dst, uint256 tokenId) public {
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
    function safeTransferFrom(address src, address dst, uint256 tokenId, bytes memory data) public nonReentrant {
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
    function safeTransferInternal(address src, address dst, uint256 tokenId, bytes memory data) internal {
        transferInternal(src, dst, tokenId);
        require(_checkOnERC721Received(src, dst, tokenId, data), "transfer to non ERC721Receiver implementer");
    }


    /// @dev Returns whether `spender` is allowed to manage `tokenId`.
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
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

        require(
            msg.sender == owner || isApprovedForAll(owner, msg.sender),
            "approve caller is not owner nor approved for all"
        );

        approveInternal(to, tokenId);
    }

    function approveInternal(address to, uint256 tokenId) internal {
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
    function getApproved(uint256 tokenId) public view returns (address) {
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
    function balanceOf(address owner) external view returns (uint256) {
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
    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = tokensOwners[tokenId];
        require(owner != address(0), "owner query for nonexistent token");
        return owner;
    }

    /**
     * @dev Gets the token ID at a given index of the tokens list of the requested owner.
     * @param owner address owning the tokens list to be accessed
     * @param index uint256 representing the index to be accessed of the requested tokens list
     * @return uint256 token ID at the given index of the tokens list owned by the requested address
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        require(index < this.balanceOf(owner), "owner index out of bounds");
        return ownedTokens[owner][index];
    }

    /**
     * @dev Gets the total amount of tokens stored by the contract.
     * @return uint256 representing the total amount of tokens
     */
    function totalSupply() public view returns (uint256) {
        return allTokens.length;
    }

    /**
     * @dev Gets the token ID at a given index of all the tokens in this contract
     * Reverts if the index is greater or equal to the total number of tokens.
     * @param index uint256 representing the index to be accessed of the tokens list
     * @return uint256 token ID at the given index of the tokens list
     */
    function tokenByIndex(uint256 index) public view returns (uint256) {
        require(index < totalSupply(), "global index out of bounds");
        return allTokens[index];
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
     * @dev Function to simply retrieve block number
     *  This exists mainly for inheriting test contracts to stub this result.
     */
    function getBlockNumber() internal view returns (uint) {
        return block.number;
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
     */
    function mint(uint tokenId) external {
        mintInternal(tokenId);
    }

    function safeMint(uint256 tokenId) external {
        safeMintInternal(tokenId, "");
    }

    function safeMint(uint256 tokenId, bytes calldata data) external {
        safeMintInternal(tokenId, data);
    }

    /**
     * @notice Sender supplies assets into the market and receives pTokens in exchange
     * @param tokenId The token ID
     */
    function mintInternal(uint tokenId) internal nonReentrant {
        // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
        mintFresh(msg.sender, tokenId);
    }

    function safeMintInternal(uint256 tokenId, bytes memory data) internal {
        mintInternal(tokenId);
        require(_checkOnERC721Received(address(0), msg.sender, tokenId, data), "transfer to non ERC721Receiver implementer");
    }

    /**
     * @notice User supplies assets into the market and receives pTokens in exchange
     * @param minter The address of the account which is supplying the assets
     * @param tokenId The token ID
     */
    function mintFresh(address minter, uint tokenId) internal {
        require(minter != address(0), "mint to the zero address");
        require(!_exists(tokenId), "token already minted");

        // Fail if mint not allowed
        uint allowed = comptroller.mintNFTAllowed(address(this), minter, tokenId);
        require(allowed == 0, "COMPTROLLER_REJECTION: MINT_COMPTROLLER_REJECTION");

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        doTransferIn(minter, tokenId);

        /*
         * We calculate the new total supply of pTokens and minter token balance, checking for overflow:
         *  accountTokensNew = accountTokens[minter] + 1
         */

        uint accountTokensNew = add_(accountTokens[minter], 1);

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
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @param tokenId The token ID
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint tokenId) external {
        return redeemInternal(tokenId);
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @param tokenId The token ID
     */
    function redeemInternal(uint tokenId) internal nonReentrant {
        // redeemFresh emits redeem-specific logs on errors, so we don't need to
        require(_isApprovedOrOwner(msg.sender, tokenId), "caller is not owner nor approved");
        redeemFresh(tokenId);
    }

    /**
     * @notice User redeems pTokens in exchange for the underlying asset
     * @param tokenId The token ID
     */
    function redeemFresh(uint tokenId) internal {
        address owner = ownerOf(tokenId);

        // Fail if redeem not allowed
        uint allowed = comptroller.redeemNFTAllowed(address(this), owner, tokenId);
        require(allowed == 0, "COMPTROLLER_REJECTION: MINT_COMPTROLLER_REJECTION");

        /*
         * We calculate the new owner balance, checking for underflow:
         *  accountTokensNew = accountTokens[owner] - 1
         */

        uint accountTokensNew = sub_(accountTokens[owner], 1);

        /////////////////////////
        // EFFECTS & INTERACTIONS
        // (No safe failures beyond this point)

        // We invoke doTransferOut for the owner
        doTransferOut(owner, tokenId);

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
        emit Redeem(owner, tokenId);

        // We call the defense hook
        comptroller.redeemNFTVerify(address(this), owner, tokenId);
    }

    function liquidateCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (uint) {
        return liquidateCollateralInternal(msg.sender, borrower, tokenId, NFTLiquidationExchangePTokenAddress, false);
    }

    function liquidateSeizeCollateral(address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress) external returns (uint) {
        return liquidateCollateralInternal(msg.sender, borrower, tokenId, NFTLiquidationExchangePTokenAddress, true);
    }

    function liquidateCollateralInternal(address liquidator, address borrower, uint tokenId, address NFTLiquidationExchangePTokenAddress, bool liquidatorSeize) internal nonReentrant returns (uint) { // NFT TODO liquidatorSeize ???
        require(ownerOf(tokenId) == borrower, "incorrect borrower");

        // Fail if borrower = caller
        if (borrower == liquidator) {
            return fail(Error.INVALID_ACCOUNT_PAIR, FailureInfo.LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER);
        }

        // Fail if liquidateCollateral not allowed
        uint allowed = comptroller.liquidateNFTCollateralAllowed(address(this), liquidator, borrower, tokenId, NFTLiquidationExchangePTokenAddress);
        if (allowed != 0) {
            return failOpaque(Error.COMPTROLLER_REJECTION, FailureInfo.LIQUIDATE_SEIZE_COMPTROLLER_REJECTION, allowed);
        }

        PErc20Interface NFTLiquidationExchangePToken = PErc20Interface(NFTLiquidationExchangePTokenAddress);

        // double-check
        (, , uint beforeLiquidityShortfall) = comptroller.getAccountLiquidity(borrower);
        assert(beforeLiquidityShortfall > 0);

        // liquidate collateral
        uint result = liquidateCollateralInternalImpl(liquidator, borrower, tokenId, NFTLiquidationExchangePToken, liquidatorSeize);

        // double-check
        (, , uint liquidityShortfall) = comptroller.getAccountLiquidity(borrower);
        require(beforeLiquidityShortfall >= liquidityShortfall, "invalid liquidity after the exchange");

        return result;
    }

    function liquidateCollateralInternalImpl(address liquidator, address borrower, uint tokenId, PErc20Interface NFTLiquidationExchangePToken, bool liquidatorSeize) internal returns (uint) { // NFT TODO liquidatorSeize ???
        uint256 exchangePTokenBalanceBefore = NFTLiquidationExchangePToken.balanceOf(address(this));
        uint liquidationIncentive;
        uint pbxBonusIncentive;

        if (liquidatorSeize) { // sell underlying NFT to liquidator
            uint seizeValueToReceive;
            (, liquidationIncentive, pbxBonusIncentive, seizeValueToReceive) = comptroller.nftLiquidateCalculateValues(address(this), tokenId, address(NFTLiquidationExchangePToken));
            require(seizeValueToReceive > 0, "liquidateSeizeCollateral not possible");
            _exchangeUnderlying(borrower, tokenId, seizeValueToReceive, liquidationIncentive, liquidator, true, NFTLiquidationExchangePToken);
        } else { // exchange underlying NFT for NFTLiquidationExchangePToken
            uint minAmountToReceiveOnExchange;
            (minAmountToReceiveOnExchange, liquidationIncentive, pbxBonusIncentive, ) = comptroller.nftLiquidateCalculateValues(address(this), tokenId, address(NFTLiquidationExchangePToken));
            require(minAmountToReceiveOnExchange > 0, "liquidateCollateral not possible");
            _exchangeUnderlying(borrower, tokenId, minAmountToReceiveOnExchange, liquidationIncentive, liquidator, false, NFTLiquidationExchangePToken);
        }

        // send liquidation incentive
        // approve already called in _exchangeUnderlying
        require(NFTLiquidationExchangePToken.mint(liquidationIncentive) == uint(Error.NO_ERROR), "NFTLiquidationExchangePToken mint incentive failed");
        require(NFTLiquidationExchangePToken.transfer(liquidator, NFTLiquidationExchangePToken.balanceOf(address(this)) - exchangePTokenBalanceBefore), "NFTLiquidationExchangePToken transfer incentive failed");

        // send PBX bonus liquidation incentive
        comptroller.nftLiquidateSendPBXBonusIncentive(pbxBonusIncentive, liquidator);

        assert(NFTLiquidationExchangePToken.balanceOf(address(this)) == exchangePTokenBalanceBefore); // double-check

        // We emit a LiquidateCollateral event
        emit LiquidateCollateral(liquidator, borrower, tokenId, address(NFTLiquidationExchangePToken));  // NFT TODO different events?

        // We call the defense hook
        comptroller.liquidateNFTCollateralVerify(address(this), liquidator, borrower, tokenId);

        return uint(Error.NO_ERROR);
    }

    function _sellUnderlyingOnSudoswap(uint tokenId, uint minAmountToReceive, PErc20Interface NFTLiquidationExchangePToken) internal {
        assert(SudoswapLSSVMPairAddress != address(0));
        assert(comptroller.SudoswapPairRouterAddress() != address(0));

        LSSVMPairERC20Interface SudoswapLSSVMPair = LSSVMPairERC20Interface(SudoswapLSSVMPairAddress);
        EIP20Interface NFTLiquidationExchangeToken = EIP20Interface(NFTLiquidationExchangePToken.underlying());

        require(SudoswapLSSVMPair.nft() == underlying, "wrong SudoswapLSSVMPair.nft()");
        require(SudoswapLSSVMPair.token() == address(NFTLiquidationExchangeToken), "wrong SudoswapLSSVMPair.token()");

        // sell underlying on Sudoswap
        bytes memory encodedSig = abi.encodePacked(
            bytes4(keccak256("swapNFTsForToken((address,uint256[])[],uint256,address,uint256)")), // function signature
            // function arguments
            abi.encodePacked(uint256(128),
                             uint256(minAmountToReceive),
                             uint256(address(this)),
                             uint256(block.timestamp),
                             uint256(1),
                             uint256(32),
                             uint256(SudoswapLSSVMPairAddress),
                             uint256(64),
                             uint256(1),
                             uint256(tokenId))
        );

        approveUnderlying(tokenId, SudoswapLSSVMPairAddress);

        (bool success, bytes memory returnData) = comptroller.SudoswapPairRouterAddress().call(encodedSig);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }

        require(abi.decode(returnData, (uint256)) >= minAmountToReceive);
    }

    function _sellUnderlyingToLiquidator(uint tokenId, uint amountToReceive, address liquidator, PErc20Interface NFTLiquidationExchangePToken) internal {
        doErc20TransferIn(NFTLiquidationExchangePToken.underlying(), liquidator, amountToReceive);
        doTransferOut(liquidator, tokenId); // NFT TODO transfer PNFTToken instead of underlying?
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doErc20TransferIn(address tokenAddress, address from, uint amount) internal { // NFT TODO ??
        EIP20NonStandardInterface token = EIP20NonStandardInterface(tokenAddress);
        uint balanceBefore = EIP20Interface(tokenAddress).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
                case 0 {                       // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                      // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of external call
                }
                default {                      // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        uint balanceAfter = EIP20Interface(tokenAddress).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "TOKEN_TRANSFER_IN_OVERFLOW");
        require(balanceAfter - balanceBefore == amount); // underflow already checked above, just subtract
    }

    function _sellUnderlyingOnNFTXio(uint tokenId, uint minAmountToReceive, PErc20Interface NFTLiquidationExchangePToken) internal {
        assert(NFTXioVaultId >= 0);
        assert(comptroller.NFTXioMarketplaceZapAddress() != address(0));

        INFTXMarketplaceZap NFTXioMarketplace = INFTXMarketplaceZap(comptroller.NFTXioMarketplaceZapAddress());
        EIP20Interface NFTLiquidationExchangeToken = EIP20Interface(NFTLiquidationExchangePToken.underlying());

        // sell underlying for NFTLiquidationExchangeToken
        address[] memory path = new address[](2);
        path[0] = NFTXioMarketplace.nftxFactory().vault(uint(NFTXioVaultId));
        path[1] = address(NFTLiquidationExchangeToken);
        require(INFTXVault(path[0]).assetAddress() == underlying, "wrong NFTXVaultId");

        approveUnderlying(tokenId, address(NFTXioMarketplace));

        uint[] memory ids = new uint[](1);
        ids[0] = tokenId;

        NFTXioMarketplace.mintAndSell721WETH(uint(NFTXioVaultId), ids, minAmountToReceive, path, address(this));
    }

    function _exchangeUnderlying(address owner, uint tokenId, uint minAmountToReceive, uint liquidationIncentive, address liquidator, bool liquidatorSeize, PErc20Interface NFTLiquidationExchangePToken) internal {
        // NFT TODO depositBehalf ??
        assert(ownerOf(tokenId) == owner);
        require(minAmountToReceive > liquidationIncentive && liquidationIncentive > 0, "liquidateCollateral not possible");

        EIP20Interface NFTLiquidationExchangeToken = EIP20Interface(NFTLiquidationExchangePToken.underlying());

        uint256 exchangeTokenBalanceBefore = NFTLiquidationExchangeToken.balanceOf(address(this));
        uint256 exchangePTokenBalanceBefore = NFTLiquidationExchangePToken.balanceOf(address(this));

        if (liquidatorSeize) { // sell underlying NFT to liquidator
            _sellUnderlyingToLiquidator(tokenId, minAmountToReceive, liquidator, NFTLiquidationExchangePToken);
        } else { // exchange underlying NFT for NFTLiquidationExchangePToken
            _sellUnderlyingOnNFTXio(tokenId, minAmountToReceive, NFTLiquidationExchangePToken);
//            _sellUnderlyingOnSudoswap(tokenId, minAmountToReceive, NFTLiquidationExchangePToken); // NFT TODO
        }

        uint amountReceived = NFTLiquidationExchangeToken.balanceOf(address(this)) - exchangeTokenBalanceBefore;
        require(amountReceived >= minAmountToReceive, "incorrect amount received");
        // address(this) has NFTLiquidationExchangeToken now

        // exchange NFTLiquidationExchangeToken for its PToken
        require(NFTLiquidationExchangeToken.approve(address(NFTLiquidationExchangePToken), amountReceived), "NFTLiquidationExchangeToken approve failed");
        require(NFTLiquidationExchangePToken.mint(amountReceived - liquidationIncentive) == uint(Error.NO_ERROR), "NFTLiquidationExchangePToken mint failed");

        // transfer NFTLiquidationExchangePToken to owner
        require(NFTLiquidationExchangePToken.transfer(owner, NFTLiquidationExchangePToken.balanceOf(address(this)) - exchangePTokenBalanceBefore), "NFTLiquidationExchangePToken transfer to owner failed");

        // burn pNFTToken
        approveInternal(address(0), tokenId);
        _removeTokenFromOwnerEnumeration(owner, tokenId);
        ownedTokensIndex[tokenId] = 0;
        _removeTokenFromAllTokensEnumeration(tokenId);
        uint accountTokensNew = sub_(accountTokens[owner], 1);
        accountTokens[owner] = accountTokensNew;
        tokensOwners[tokenId] = address(0);
        emit Transfer(owner, address(0), tokenId);
    }

    /*** Admin Functions ***/

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      */
    function _setPendingAdmin(address payable newPendingAdmin) external {
        require(msg.sender == admin, "only admin");

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
        require(ComptrollerNFTInterface(newComptroller).isComptroller());

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

        // NFT TODO
        // require(LSSVMPairERC20Interface(newSudoswapLSSVMPairAddress).nft() == underlying, "wrong newSudoswapLSSVMPairAddress.nft()");
        // require(LSSVMPairERC20Interface(newSudoswapLSSVMPairAddress).token() == PErc20Interface(comptroller.NFTLiquidationExchangePToken()).underlying(), "wrong newSudoswapLSSVMPairAddress.token()");
        //
        // SudoswapLSSVMPairAddress = newSudoswapLSSVMPairAddress;
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying owned by this contract
     */
    function getCashPrior() internal view returns (uint);

    function checkIfOwnsUnderlying(uint tokenId) internal view returns (bool);

    function approveUnderlying(uint256 tokenId, address addr) internal;

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

    /*** Reentrancy Guard ***/

    /// @dev Prevents a contract from calling itself, directly or indirectly.
    modifier nonReentrant() {
        require(_notEntered, "reentered");
        _notEntered = false;
        _;
        _notEntered = true;
        // get a gas-refund post-Istanbul
    }
}
