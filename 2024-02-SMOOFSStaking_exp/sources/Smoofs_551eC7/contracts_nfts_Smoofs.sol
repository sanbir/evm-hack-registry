// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.0;
pragma abicoder v2;

import './ISmoofs.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/utils/Strings.sol';

contract Smoofs is ISmoofs, AccessControl, ERC721Enumerable, Ownable {
    bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE');

    bool private checkOperator = true;
    bool private unrevealed = true;
    string private unrevealedURI;
    string private tokenURISuffix;

    string public baseURI;
    uint256 public maxSupply;
    uint256 public nextId = 1;

    mapping(address => bool) private allowedOperators;

    event AllowedOperatorUpdate(address signer, bool isRemoval);
    event CheckOperatorUpdate(bool _checkOperator);
    event UnrevealedUpdate(bool _unrevealed);
    event NewBaseUri(string uri);

    constructor() ERC721('Smoofs', 'SMOOFS') {
        maxSupply = 8000;
        unrevealedURI = 'https://ipfs.io/ipfs/QmfLVESoFY6qHwYfEc7NxyQH4JaJqqzPFmhJWsUrxBjMxX/1.json';
        tokenURISuffix = '.json';
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to) public onlyRole(MINTER_ROLE) {
        require(nextId <= maxSupply, 'MaxSupplyExceeded');
        _safeMint(to, nextId);
        nextId += 1;
    }

    function batchMint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(amount > 0, 'InvalidAmount');
        require(nextId + amount <= maxSupply + 1, 'MaxSupplyExceeded');
        for (uint256 i = 0; i < amount; i++) {
            _safeMint(to, nextId);
            nextId += 1;
        }
    }

    function grantMinterRole(address account) public onlyOwner {
        grantRole(MINTER_ROLE, account);
    }

    function revokeMinterRole(address account) public onlyOwner {
        revokeRole(MINTER_ROLE, account);
    }

    function updateAllowedOperators(
        address[] memory toAdd,
        address[] memory toRemove
    ) external onlyOwner {
        for (uint256 i = 0; i < toAdd.length; i++) {
            allowedOperators[toAdd[i]] = true;
            emit AllowedOperatorUpdate(toAdd[i], false);
        }
        for (uint256 i = 0; i < toRemove.length; i++) {
            delete allowedOperators[toRemove[i]];
            emit AllowedOperatorUpdate(toRemove[i], true);
        }
    }

    function setCheckOperator(bool _checkOperator) external onlyOwner {
        checkOperator = _checkOperator;
        emit CheckOperatorUpdate(_checkOperator);
    }

    function _checkAllowedOperator(address operator) internal view virtual {
        if (checkOperator) {
            require(allowedOperators[operator], 'OperatorNotAllowed');
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override {
        if (from != address(0) && from != msg.sender) {
            _checkAllowedOperator(msg.sender);
        }
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function setApprovalForAll(address operator, bool approved) public override(ERC721, IERC721) {
        _checkAllowedOperator(operator);
        super.setApprovalForAll(operator, approved);
    }

    function approve(address operator, uint256 tokenId) public override(ERC721, IERC721) {
        _checkAllowedOperator(operator);
        super.approve(operator, tokenId);
    }

    function setUnrevealed(bool _unrevealed) external onlyOwner {
        unrevealed = _unrevealed;
        emit UnrevealedUpdate(_unrevealed);
    }

    function setUnrevealedURI(string memory _unrevealedURI) external onlyOwner {
        unrevealedURI = _unrevealedURI;
    }

    function setTokenURISuffix(string memory _tokenURISuffix) external onlyOwner {
        tokenURISuffix = _tokenURISuffix;
    }

    function setBaseURI(string memory uri) external onlyOwner {
        baseURI = uri;
        emit NewBaseUri(uri);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        _requireMinted(tokenId);
        if (unrevealed) {
            return unrevealedURI;
        } else if (bytes(baseURI).length != 0) {
            return string(abi.encodePacked(baseURI, Strings.toString(tokenId), tokenURISuffix));
        }
        return '';
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Enumerable, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
