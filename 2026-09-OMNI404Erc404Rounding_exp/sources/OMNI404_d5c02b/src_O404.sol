// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DoubleEndedQueue} from "./utils/DoubleEndedQueue.sol";
import {IERC404} from "./interfaces/IERC404.sol";
import {IOFT, OFTCore} from "LayerZero-v2/oapp/contracts/oft/OFTCore.sol";

abstract contract ERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external virtual returns (bytes4) {
        return ERC721Receiver.onERC721Received.selector;
    }
}

/**
 * @title O404 Contract
 * @dev O404 is an ERC-404 token that extends the functionality of the OFTCore contract.
 */
abstract contract O404 is OFTCore, IERC404 {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    /// @dev The queue of ERC-721 tokens stored in the contract.
    DoubleEndedQueue.Bytes32Deque private _storedERC721Ids;

    // //////// Events ////////

    // event ERC20Transfer(address indexed from, address indexed to, uint256 amount);
    // event Approval(address indexed owner, address indexed spender, uint256 amount);
    // event Transfer(address indexed from, address indexed to, uint256 indexed id);
    // event ERC721Approval(address indexed owner, address indexed spender, uint256 indexed id);
    // event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // //////// Errors ////////

    // error NotFound();
    // error AlreadyExists();
    // error InvalidRecipient();
    // error InvalidSender();
    // error UnsafeRecipient();

    //////// Metadata ////////

    /// @dev Token name
    string public name;

    /// @dev Token symbol
    string public symbol;

    /// @dev Decimals for ERC-20 representation: fixed at 18
    uint8 public immutable decimals = 18;

    /// @dev Units for ERC-20 representation: fixed at 10^18
    uint256 public immutable units = 10 ** decimals;

    /// @dev Max supply for ERC-20 representation
    uint256 public immutable maxTotalSupplyERC20;

    /// @dev Max supply for ERC-721 representation
    uint256 public immutable maxTotalSupplyERC721;

    /// @dev Total supply in ERC-20 representation
    uint256 public totalSupply;

    /// @dev Current mint counter which also represents the highest minted id, monotonically increasing to ensure accurate ownership
    uint256 public minted;

    //////// Mappings ////////

    /// @dev Balance of user in ERC-20 representation
    mapping(address => uint256) public balanceOf;

    /// @dev Allowance of user in ERC-20 representation
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Approval in ERC-721 representaion
    mapping(uint256 => address) public getApproved;

    /// @dev Approval for all in ERC-721 representation
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @dev Owner of id in ERC-721 representation
    mapping(uint256 => address) internal _ownerOf; // TODO: check

    /// @dev Array of owned ids in ERC-721 representation
    mapping(address => uint256[]) internal _owned; // TODO: check

    /// @dev Tracks indices for the _owned mapping
    mapping(uint256 => uint256) internal _ownedIndex; // TODO: check

    /// @dev Addresses whitelisted from minting / burning for gas savings (pairs, routers, etc)
    mapping(address => bool) public whitelist;

    /**
     * @dev Constructor for the OFT contract.
     * @param _name The name of the OFT.
     * @param _symbol The symbol of the OFT.
     * @param _maxTotalSupplyERC721 Max supply for ERC-721 representation
     * @param _lzEndpoint The LayerZero endpoint address.
     * @param _delegate The delegate capable of making OApp configurations inside of the endpoint.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxTotalSupplyERC721,
        address _lzEndpoint,
        address _delegate
    ) OFTCore(decimals, _lzEndpoint, _delegate) {
        name = _name;
        symbol = _symbol;
        maxTotalSupplyERC721 = _maxTotalSupplyERC721;
        maxTotalSupplyERC20 = maxTotalSupplyERC721 * units;
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // OFT FUNCTIONS

    /**
     * @notice Retrieves interfaceID and the version of the OFT.
     * @return interfaceId The interface ID.
     * @return version The version.
     *
     * @dev interfaceId: This specific interface ID is '0x02e49c2c'.
     * @dev version: Indicates a cross-chain compatible msg encoding with other OFTs.
     * @dev If a new feature is added to the OFT cross-chain msg encoding, the version will be incremented.
     * ie. localOFT version(x,1) CAN send messages to remoteOFT version(x,1)
     */
    function oftVersion() external pure virtual returns (bytes4 interfaceId, uint64 version) {
        return (type(IOFT).interfaceId, 1);
    }

    /**
     * @dev Retrieves the address of the underlying ERC20 implementation.
     * @return The address of the OFT token.
     *
     * @dev In the case of OFT, address(this) and erc20 are the same contract.
     */
    function token() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Indicates whether the OFT contract requires approval of the 'token()' to send.
     * @return requiresApproval Needs approval of the underlying token implementation.
     *
     * @dev In the case of OFT where the contract IS the token, approval is NOT required.
     */
    function approvalRequired() external pure virtual returns (bool) {
        return false;
    }

    /**
     * @dev Burns tokens from the sender's specified balance.
     * @param _amountLD The amount of tokens to send in local decimals.
     * @param _minAmountLD The minimum amount to send in local decimals.
     * @param _dstEid The destination chain ID.
     * @return amountSentLD The amount sent in local decimals.
     * @return amountReceivedLD The amount received in local decimals on the remote.
     */
    function _debit(uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // @dev In NON-default OFT, amountSentLD could be 100, with a 10% fee, the amountReceivedLD amount is 90,
        // therefore amountSentLD CAN differ from amountReceivedLD.

        // @dev Default OFT burns on src.
        _burnERC20(msg.sender, amountSentLD);
    }

    /**
     * @dev Credits tokens to the specified address.
     * @param _to The address to credit the tokens to.
     * @param _amountLD The amount of tokens to credit in local decimals.
     * @dev _srcEid The source chain ID.
     * @return amountReceivedLD The amount of tokens ACTUALLY received in local decimals.
     */
    function _credit(address _to, uint256 _amountLD, uint32 /*_srcEid*/ )
        internal
        virtual
        override
        returns (uint256 amountReceivedLD)
    {
        // @dev Default OFT mints on dst.
        _mintERC20(_to, _amountLD);
        // @dev In the case of NON-default OFT, the _amountLD MIGHT not be == amountReceivedLD.
        return _amountLD;
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // ERC404 FUNCTIONS

    /// @notice Function to find owner of a given ERC-721 token
    function ownerOf(uint256 id_) public view virtual returns (address nftOwner) {
        nftOwner = _ownerOf[id_];

        // If the id_ is beyond the range of ERC-721 supply, is 0, or the token is not owned by anyone, revert.
        if (id_ > maxTotalSupplyERC721 || id_ == 0 || nftOwner == address(0)) {
            revert NotFound();
        }
    }

    function erc721BalanceOf(address owner_) public view virtual returns (uint256) {
        return _owned[owner_].length;
    }

    function erc20BalanceOf(address owner_) public view virtual returns (uint256) {
        return balanceOf[owner_];
    }

    /// @notice Function for token approvals
    /// @dev This function assumes the operator is attempting to approve an ERC-721 if valueOrId is less than the minted count. Note: Unlike setApprovalForAll, spender_ must be allowed to be 0x0 so that approval can be revoked.
    function approve(address spender_, uint256 valueOrId_) public virtual returns (bool) {
        // The ERC-721 tokens are 1-indexed, so 0 is not a valid id and indicates that operator is attempting to set the ERC-20 allowance to 0.
        if (valueOrId_ <= maxTotalSupplyERC721 && valueOrId_ > 0) {
            // Intention is to approve as ERC-721 token (id).
            uint256 id = valueOrId_;
            address nftOwner = _ownerOf[id];

            if (msg.sender != nftOwner && !isApprovedForAll[nftOwner][msg.sender]) {
                revert Unauthorized();
            }

            getApproved[id] = spender_;

            emit Approval(nftOwner, spender_, id);
            emit ERC721Approval(nftOwner, spender_, id);
        } else {
            // Intention is to approve as ERC-20 token (value).
            uint256 value = valueOrId_;
            allowance[msg.sender][spender_] = value;

            emit Approval(msg.sender, spender_, value);
            emit ERC20Approval(msg.sender, spender_, value);
        }

        return true;
    }

    /// @notice Function for ERC-721 approvals
    function setApprovalForAll(address operator_, bool approved_) public virtual {
        // Prevent approvals to 0x0.
        if (operator_ == address(0)) {
            revert InvalidOperator();
        }
        isApprovedForAll[msg.sender][operator_] = approved_;
        emit ApprovalForAll(msg.sender, operator_, approved_);
    }

    /// @notice Function for mixed transfers from an operator that may be different than 'from'.
    /// @dev This function assumes the operator is attempting to transfer an ERC-721 if valueOrId is less than or equal to current max id.
    function transferFrom(address from_, address to_, uint256 valueOrId_) public virtual returns (bool) {
        // Prevent burning tokens to the 0 address.
        // TODO: remove
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        if (valueOrId_ <= maxTotalSupplyERC721) {
            // Intention is to transfer as ERC-721 token (id).
            uint256 id = valueOrId_;

            if (from_ != _ownerOf[id]) {
                revert InvalidSender();
            }

            // Check that the operator is approved for the transfer.
            if (msg.sender != from_ && !isApprovedForAll[from_][msg.sender] && msg.sender != getApproved[id]) {
                revert Unauthorized();
            }

            // Transfer 1 * units ERC-20 and 1 ERC-721 token.
            _transferERC20(from_, to_, units);
            _transferERC721(from_, to_, id);
        } else {
            // Intention is to transfer as ERC-20 token (value).
            uint256 value = valueOrId_;
            uint256 allowed = allowance[from_][msg.sender];

            // Check that the operator has sufficient allowance.
            if (allowed != type(uint256).max) {
                if (allowed < value) {
                    revert InsufficientAllowance();
                }
                allowance[from_][msg.sender] = allowed - value;
            }

            // Transferring ERC-20s directly requires the _transfer function.
            _transfer(from_, to_, value);
        }

        return true;
    }

    /// @notice Function for mixed transfers.
    /// @dev This function assumes the operator is attempting to transfer an ERC-721 if valueOrId is lte the highest minted ERC-721 id.
    function transfer(address to_, uint256 valueOrId_) public virtual returns (bool) {
        // Prevent burning tokens to the 0 address.
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        if (valueOrId_ <= maxTotalSupplyERC721) {
            // Intention is to transfer as ERC-721 token (id).
            uint256 id = valueOrId_;

            if (msg.sender != _ownerOf[id]) {
                revert Unauthorized();
            }

            // Transfer 1 * units ERC-20 and 1 ERC-721 token.
            // This this path is used to ensure the exact ERC-721 specified is transferred.
            _transferERC20(msg.sender, to_, units);
            _transferERC721(msg.sender, to_, id);
        } else {
            // Intention is to transfer as ERC-20 token (value).
            uint256 value = valueOrId_;

            // Transferring ERC-20s directly requires the _transfer function.
            _transfer(msg.sender, to_, value);
        }

        return true;
    }

    /// @notice Function for ERC-721 transfers with contract support.
    function safeTransferFrom(address from_, address to_, uint256 id_) public virtual {
        transferFrom(from_, to_, id_);

        if (
            to_.code.length != 0
                && ERC721Receiver(to_).onERC721Received(msg.sender, from_, id_, "")
                    != ERC721Receiver.onERC721Received.selector
        ) {
            revert UnsafeRecipient();
        }
    }

    /// @notice Function for ERC-721 transfers with contract support and callback data.
    function safeTransferFrom(address from_, address to_, uint256 id_, bytes calldata data_) public virtual {
        transferFrom(from_, to_, id_);

        if (
            to_.code.length != 0
                && ERC721Receiver(to_).onERC721Received(msg.sender, from_, id_, data_)
                    != ERC721Receiver.onERC721Received.selector
        ) {
            revert UnsafeRecipient();
        }
    }

    /// @notice This is the lowest level ERC-20 transfer function, which should be used for both normal ERC-20 transfers as well as minting.
    /// Note that this function allows transfers to and from 0x0.
    function _transferERC20(address from_, address to_, uint256 value_) internal virtual {
        // Minting is a special case for which we should not check the balance of the sender, and we should increase the total supply.
        if (from_ == address(0)) {
            if (totalSupply + value_ > maxTotalSupplyERC20) {
                revert MaxERC20SupplyReached();
            }
            unchecked {
                totalSupply += value_;
            }
        } else {
            // For transfers not from the 0x0 address, check for insufficient balance.
            if (balanceOf[from_] < value_) {
                revert InsufficientBalance();
            }
            // Deduct value from sender's balance.
            balanceOf[from_] -= value_;

            // If the recipient is the 0x0 address, burn the tokens.
            if (to_ == address(0)) {
                // Burning is a special case for which we should decrease the total supply.
                unchecked {
                    totalSupply -= value_;
                }
            }
        }

        // If this is not a burn
        if (to_ != address(0)) {
            // Update the recipient's balance.
            unchecked {
                balanceOf[to_] += value_;
            }
        }

        emit Transfer(from_, to_, value_);
        emit ERC20Transfer(from_, to_, value_);
    }

    /// @notice Consolidated record keeping function for transferring ERC-721s.
    /// @dev Assign the token to the new owner, and remove from the old owner.
    /// Note that this function allows transfers to and from 0x0.
    function _transferERC721(address from_, address to_, uint256 id_) internal virtual {
        // If this is not a mint, handle record keeping for transfer from previous owner.
        if (from_ != address(0)) {
            // On transfer of an NFT, any previous approval is reset.
            delete getApproved[id_];

            // update _owned for sender
            uint256 updatedId = _owned[from_][_owned[from_].length - 1];
            _owned[from_][_ownedIndex[id_]] = updatedId;
            // pop
            _owned[from_].pop();
            // update index for the moved id
            _ownedIndex[updatedId] = _ownedIndex[id_];
        }

        // Update owner of the token to the new owner.
        _ownerOf[id_] = to_;
        // Push token onto the new owner's stack.
        _owned[to_].push(id_);
        // Update index for new owner's stack.
        _ownedIndex[id_] = _owned[to_].length - 1;

        emit Transfer(from_, to_, id_);
        emit ERC721Transfer(from_, to_, id_);
    }

    /// @notice Internal function for ERC-20 transfers.
    ///         Also handles any ERC-721 transfers that may be required.
    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        uint256 erc20BalanceOfSenderBefore = erc20BalanceOf(from);
        uint256 erc20BalanceOfReceiverBefore = erc20BalanceOf(to);

        _transferERC20(from, to, amount);

        // Skip burn for certain addresses to save gas
        if (!whitelist[from]) {
            uint256 num721ToBurn = (erc20BalanceOfSenderBefore / units) - (balanceOf[from] / units);
            for (uint256 i = 0; i < num721ToBurn; i++) {
                _burnERC721(from);
            }
        }

        // Skip minting for certain addresses to save gas
        if (!whitelist[to]) {
            uint256 num721ToMint = (balanceOf[to] / units) - (erc20BalanceOfReceiverBefore / units);
            for (uint256 i = 0; i < num721ToMint; i++) {
                _mintERC721(to);
            }
        }

        return true;
    }

    /// @notice Internal function for ERC20 minting
    /// @dev This function will allow minting of new ERC20s up to the maxTotalSupplyERC20.
    function _mintERC20(address to_, uint256 value_) internal virtual {
        /// You cannot mint to the zero address (you can't mint and immediately burn in the same transfer).
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        uint256 erc20BalanceOfReceiverBefore = erc20BalanceOf(to_);

        _transferERC20(address(0), to_, value_);

        if (!whitelist[to_]) {
            uint256 num721ToMint = (balanceOf[to_] / units) - (erc20BalanceOfReceiverBefore / units);
            for (uint256 i = 0; i < num721ToMint; i++) {
                _mintERC721(to_);
            }
        }
    }

    function _burnERC20(address from_, uint256 value_) internal virtual {
        /// You cannot mint to the zero address (you can't mint and immediately burn in the same transfer).
        if (from_ == address(0)) {
            revert InvalidSender();
        }

        uint256 erc20BalanceOfSenderBefore = erc20BalanceOf(from_);

        _transferERC20(from_, address(0), value_);

        // Skip burn for certain addresses to save gas
        if (!whitelist[from_]) {
            uint256 num721ToBurn = (erc20BalanceOfSenderBefore / units) - (balanceOf[from_] / units);
            for (uint256 i = 0; i < num721ToBurn; i++) {
                _burnERC721(from_);
            }
        }
    }

    /// @notice Internal function for ERC-721 minting and retrieval from the bank.
    /// @dev This function will allow minting of new ERC-721s up to the maxTotalSupplyERC20. It will first try to pull from the bank, and if the bank is empty, it will mint a new token.
    function _mintERC721(address to_) internal virtual {
        if (to_ == address(0) || to_ == address(this)) {
            revert InvalidRecipient();
        }

        uint256 id;

        if (!DoubleEndedQueue.empty(_storedERC721Ids)) {
            // If there are any tokens in the bank, use those.
            id = uint256(_storedERC721Ids.popBack());
        } else {
            // Otherwise, mint a new token.
            minted++;
            id = minted;
            if (minted > maxTotalSupplyERC721) {
                revert MaxERC721SupplyReached();
            }
        }

        address nftOwner = _ownerOf[id];

        // The token should not already belong to anyone besides 0x0 or this contract. If it does, something is wrong, as this should never happen.
        if (nftOwner != address(0) && nftOwner != address(this)) {
            revert AlreadyExists();
        }

        // Transfer the token to the recipient, either transferring from the contract's bank or minting.
        _transferERC721(nftOwner, to_, id);
    }

    /// @notice Internal function for ERC-721 deposits to bank (this contract).
    /// @dev This function will allow depositing of ERC-721s to the bank, which can be retrieved by future minters.
    function _burnERC721(address from_) internal virtual {
        if (from_ == address(0) || from_ == address(this)) {
            revert InvalidSender();
        }

        // Retrieve the latest token added to the owner's stack (LIFO).
        uint256 id = _owned[from_][_owned[from_].length - 1];

        // Transfer the token to the contract.
        _transferERC721(from_, address(this), id); // TODO: should this be set to address(0) ?

        // Record the token in the contract's bank queue.
        _storedERC721Ids.pushFront(bytes32(id));
    }

    /// @notice Initialization function to set pairs / etc, saving gas by avoiding mint / burn on unnecessary targets
    function _setWhitelist(address target_, bool state_) internal virtual {
        // If the target has at least 1 full ERC-20 token, they should not be removed from the whitelist because if they were and then they attempted to transfer, it would revert as they would not necessarily have ehough ERC-721s to bank.
        if (erc20BalanceOf(target_) >= units && !state_) {
            revert CannotRemoveFromWhitelist();
        }
        whitelist[target_] = state_;
    }
}
