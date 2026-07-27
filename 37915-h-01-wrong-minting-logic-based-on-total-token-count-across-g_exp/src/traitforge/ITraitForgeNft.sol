// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol';

interface ITraitForgeNft is IERC721Enumerable {
  // Events for logging contract activities
  event Minted(
    address indexed minter,
    uint256 indexed itemId,
    uint256 indexed generation,
    uint256 entropyValue,
    uint256 mintPrice
  );
  event NewEntityMinted(
    address indexed owner,
    uint256 indexed tokenId,
    uint256 indexed generation,
    uint256 entropy
  );
  event GenerationIncremented(uint256 newGeneration);
  event FundsDistributedToNukeFund(address indexed to, uint256 amount);
  event NukeFundContractUpdated(address nukeFundAddress);

  function setNukeFundContract(address payable _nukeFundAddress) external;

  function setEntityForgingContract(address _entityForgingAddress) external;

  function setEntropyGenerator(address _entropyGeneratorAddress) external;

  function setAirdropContract(address _airdrop) external;

  function setStartPrice(uint256 _startPrice) external;

  function setPriceIncrement(uint256 _priceIncrement) external;

  function setPriceIncrementByGen(uint256 _priceIncrementByGen) external;

  function startAirdrop(uint256 amount) external;

  function isApprovedOrOwner(
    address spender,
    uint256 tokenId
  ) external view returns (bool);

  function burn(uint256 tokenId) external;

  function forge(
    address newOwner,
    uint256 parent1Id,
    uint256 parent2Id,
    string memory baseTokenURI
  ) external returns (uint256);

  function mintToken(bytes32[] calldata proof) external payable;

  function mintWithBudget(bytes32[] calldata proof) external payable;

  function calculateMintPrice() external view returns (uint256);

  function getTokenEntropy(uint256 tokenId) external view returns (uint256);

  function getTokenGeneration(uint256 tokenId) external view returns (uint256);

  function getEntropiesForTokens(
    uint256 forgerTokenId,
    uint256 mergerTokenId
  ) external view returns (uint256 forgerEntropy, uint256 mergerEntropy);

  function getTokenLastTransferredTimestamp(
    uint256 tokenId
  ) external view returns (uint256);

  function getTokenCreationTimestamp(
    uint256 tokenId
  ) external view returns (uint256);

  function isForger(uint256 tokenId) external view returns (bool);
}
