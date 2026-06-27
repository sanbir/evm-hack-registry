// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.0 (token/ERC20/IERC20.sol)
pragma solidity ^0.8.19;

import "./ERC721Enumerable.sol";
import {DoubleEndedQueue} from "./DoubleEndedQueue.sol";

interface IERC20 {
    function mint(address to, uint256 amount) external;
}

contract P404NFT is ERC721Enumerable {
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    /// @dev The queue of ERC-721 tokens stored in the contract.
    DoubleEndedQueue.Uint256Deque private _storedERC721Ids;

    error NotFound();
    error InvalidTokenId();
    error AlreadyExists();
    error InvalidRecipient();
    error InvalidSender();
    error InvalidSpender();
    error InvalidOperator();
    error UnsafeRecipient();
    error RecipientIsERC721TransferExempt();
    error Unauthorized();
    error InsufficientAllowance();
    error DecimalsTooLow();
    error PermitDeadlineExpired();
    error InvalidSigner();
    error InvalidApproval();
    error OwnedIndexOverflow();
    error MintLimitReached();
    error InvalidExemption();

    address public owner;

    address public p404contract;

    mapping(address => bool) public minters;

    // uint256 public idTracker = 200000000 * 10 ** 18 + 1;
    uint256 public idTracker = 1;

    uint256 public constant TRANSFORM_PRICE = 10000 * 10 ** 18;
    uint256 public constant TRANSFORM_LOSE_RATE = 200; // 2%

    string private baseUri;

    event FromNFTToToken(address from, uint256 tokenId);

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC721(_name, _symbol) {
        owner = msg.sender;
    }

    function setBaseURI(string memory _baseUri) public {
        require(msg.sender == owner, "P404NFT: only owner can set baseUri");
        baseUri = _baseUri;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseUri;
    }

    function mint(address to) public {
        require(minters[msg.sender], "P404NFT: only minters can mint");
        // _mint(to, idTracker++);
        _retrieveOrMintERC721(to);
    }

    // burn
    function burn(uint256 tokenId) external {
        // address _owner = ownerOf(tokenId);
        // require(_isAuthorized(_owner, msg.sender, tokenId), "P404NFT: caller is not owner nor approved");
        require(
            p404contract == msg.sender,
            "P404NFT: only p404contract can burn"
        );
        // _burn(tokenId);
        _withdrawAndStoreERC721(tokenId);
    }

    function _setMinter(address minter, bool enable) internal {
        require(msg.sender == owner, "P404NFT: only owner can set minter");
        minters[minter] = enable;
    }

    function setOwner(address _owner) public {
        require(msg.sender == owner, "P404NFT: only owner can set owner");
        owner = _owner;
    }

    function setP404Contract(address _p404contract) public {
        require(
            msg.sender == owner,
            "P404NFT: only owner can set p404contract"
        );
        _setMinter(p404contract, false);
        p404contract = _p404contract;
        _setMinter(_p404contract, true);
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address res = super._update(to, tokenId, auth);

        if (res != address(0)) {
            if (to == address(this)) {
                revert("P404NFT: not support transform");
            } else if (to == p404contract) {
                if (msg.sender != p404contract) {
                    _erc721ToErc20(tokenId);
                }
            }
        }
        return res;
    }

    function _isAuthorized(
        address _owner,
        address _spender,
        uint256 _tokenId
    ) internal view override returns (bool) {
        // return
        //     spender != address(0) &&
        //     (owner == spender || isApprovedForAll(owner, spender) || _getApproved(tokenId) == spender);
        return
            super._isAuthorized(_owner, _spender, _tokenId) ||
            p404contract == _spender;
    }

    // // isAuthorized
    function isAuthorized(
        address _owner,
        address _spender,
        uint256 _tokenId
    ) external view returns (bool) {
        return super._isAuthorized(_owner, _spender, _tokenId);
    }

    receive() external payable {
        revert("P404NFT: not accept ether");
    }

    function _erc721ToErc20(uint256 _tokenId) internal {
        // _burn(_tokenId);
        _withdrawAndStoreERC721( _tokenId);
        IERC20(p404contract).mint(
            msg.sender,
            (TRANSFORM_PRICE * (10000 - TRANSFORM_LOSE_RATE)) / 10000
        );
        emit FromNFTToToken(msg.sender, _tokenId);
    }

    function _withdrawAndStoreERC721(
        uint256 id
    ) internal virtual {
        // if (from_ == address(0)) {
        //   revert InvalidSender();
        // }
        // Transfer to 0x0.
        // Does not handle ERC-721 exemptions.
        // _transferERC721(from_, address(0), id);
        // burn token id
        _burn(id);
        // Record the token in the contract's bank queue.
        _storedERC721Ids.pushFront(id);
    }

    function _retrieveOrMintERC721(address to_) internal virtual {
        if (to_ == address(0)) {
            revert InvalidRecipient();
        }

        uint256 id;

        if (!_storedERC721Ids.empty()) {
            // If there are any tokens in the bank, use those first.
            // Pop off the end of the queue (FIFO).
            id = _storedERC721Ids.popBack();
        } else {
            // Otherwise, mint a new token, should not be able to go over the total fractional supply.
            id = idTracker++;
        }

        address erc721Owner = _ownerOf(id);

        // The token should not already belong to anyone besides 0x0 or this contract.
        // If it does, something is wrong, as this should never happen.
        if (erc721Owner != address(0)) {
            revert AlreadyExists();
        }

        // Transfer the token to the recipient, either transferring from the contract's bank or minting.
        // Does not handle ERC-721 exemptions.
        // _transferERC721(erc721Owner, to_, id);
        _mint(to_, id);
    }
}

