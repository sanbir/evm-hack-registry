// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC721,IERC721Metadata} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';

interface IOGsNFT is IERC721, IERC721Metadata {
    event ProvenanceLocked(string provenanceHash);
    event MetadataFrozen(string baseUri);

    function petOwnerId() external view returns (uint256);
    function nonPetOwnerId() external view returns (uint256);
    function MERKLE_ROOT() external view returns (bytes32);
    function MERKLE_ROOT_ROUND_TWO() external view returns (bytes32);
    function MERKLE_ROOT_ROUND_THREE() external view returns (bytes32);
    function isRoundOneEnabled() external view returns (bool);
    function isRoundTwoEnabled() external view returns (bool);
    function isRoundThreeEnabled() external view returns (bool);
    function PROVENANCE_HASH() external view returns (string memory);
    function isProvenanceLocked() external view returns (bool);
    function baseURI() external view returns (string memory);
    function isMetadataFrozen() external view returns (bool);
    function roundOneMinted(address) external view returns (bool);
    function roundTwoMinted(address) external view returns (bool);
    function roundThreeMinted(address) external view returns (bool);
    function petOwnersMinted(address) external view returns (uint256);

    function supportsInterface(bytes4 interfaceId) external view override returns (bool);
    function totalSupply() external view returns (uint256);
    function setRoyalty(address recipient, uint96 value) external;

    function setProvenanceHash(string memory provenanceHash) external;
    function lockPrevenance() external;
    function setBaseURI(string memory __baseURI) external;
    function freezeMetadata() external;

    function tokenURI(uint256 tokenId) external view override returns (string memory);
}