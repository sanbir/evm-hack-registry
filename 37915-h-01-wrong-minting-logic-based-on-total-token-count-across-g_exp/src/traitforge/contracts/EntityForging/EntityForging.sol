// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import './IEntityForging.sol';
import '../TraitForgeNft/ITraitForgeNft.sol';

contract EntityForging is IEntityForging, ReentrancyGuard, Ownable, Pausable {
  ITraitForgeNft public nftContract;
  address payable public nukeFundAddress;
  uint256 public taxCut = 10;
  uint256 public oneYearInDays = 365 days;
  uint256 public listingCount = 0;
  uint256 public minimumListFee = 0.01 ether;

  /// @dev tokenid -> listings index
  mapping(uint256 => uint256) public listedTokenIds;
  /// @dev index -> listing info
  mapping(uint256 => Listing) public listings;
  mapping(uint256 => uint8) public forgingCounts; // track forgePotential
  mapping(uint256 => uint256) private lastForgeResetTimestamp;

  constructor(address _traitForgeNft) {
    nftContract = ITraitForgeNft(_traitForgeNft);
  }

  // allows the owner to set NukeFund address
  function setNukeFundAddress(
    address payable _nukeFundAddress
  ) external onlyOwner {
    nukeFundAddress = _nukeFundAddress;
  }

  function setTaxCut(uint256 _taxCut) external onlyOwner {
    taxCut = _taxCut;
  }

  function setOneYearInDays(uint256 value) external onlyOwner {
    oneYearInDays = value;
  }

  function setMinimumListingFee(uint256 _fee) external onlyOwner {
    minimumListFee = _fee;
  }

  function fetchListings() external view returns (Listing[] memory _listings) {
    _listings = new Listing[](listingCount + 1);
    for (uint256 i = 1; i <= listingCount; ++i) {
      _listings[i] = listings[i];
    }
  }

  function getListedTokenIds(
    uint tokenId_
  ) external view override returns (uint) {
    return listedTokenIds[tokenId_];
  }

  function getListings(
    uint id
  ) external view override returns (Listing memory) {
    return listings[id];
  }

  function listForForging(
    uint256 tokenId,
    uint256 fee
  ) public whenNotPaused nonReentrant {
    Listing memory _listingInfo = listings[listedTokenIds[tokenId]];

    require(!_listingInfo.isListed, 'Token is already listed for forging');
    require(
      nftContract.ownerOf(tokenId) == msg.sender,
      'Caller must own the token'
    );
    require(
      fee >= minimumListFee,
      'Fee should be higher than minimum listing fee'
    );

    _resetForgingCountIfNeeded(tokenId);

    uint256 entropy = nftContract.getTokenEntropy(tokenId); // Retrieve entropy for tokenId
    uint8 forgePotential = uint8((entropy / 10) % 10); // Extract the 5th digit from the entropy
    require(
      forgePotential > 0 && forgingCounts[tokenId] <= forgePotential,
      'Entity has reached its forging limit'
    );

    bool isForger = (entropy % 3) == 0; // Determine if the token is a forger based on entropy
    require(isForger, 'Only forgers can list for forging');

    ++listingCount;
    listings[listingCount] = Listing(msg.sender, tokenId, true, fee);
    listedTokenIds[tokenId] = listingCount;

    emit ListedForForging(tokenId, fee);
  }

  function forgeWithListed(
    uint256 forgerTokenId,
    uint256 mergerTokenId
  ) external payable whenNotPaused nonReentrant returns (uint256) {
    Listing memory _forgerListingInfo = listings[listedTokenIds[forgerTokenId]];
    require(
      _forgerListingInfo.isListed,
      "Forger's entity not listed for forging"
    );
    require(
      nftContract.ownerOf(mergerTokenId) == msg.sender,
      'Caller must own the merger token'
    );
    require(
      nftContract.ownerOf(forgerTokenId) != msg.sender,
      'Caller should be different from forger token owner'
    );
    require(
      nftContract.getTokenGeneration(mergerTokenId) ==
        nftContract.getTokenGeneration(forgerTokenId),
      'Invalid token generation'
    );

    uint256 forgingFee = _forgerListingInfo.fee;
    require(msg.value >= forgingFee, 'Insufficient fee for forging');

    _resetForgingCountIfNeeded(forgerTokenId); // Reset for forger if needed
    _resetForgingCountIfNeeded(mergerTokenId); // Reset for merger if needed

    // Check forger's breed count increment but do not check forge potential here
    // as it is already checked in listForForging for the forger
    forgingCounts[forgerTokenId]++;

    // Check and update for merger token's forge potential
    uint256 mergerEntropy = nftContract.getTokenEntropy(mergerTokenId);
    require(mergerEntropy % 3 != 0, 'Not merger');
    uint8 mergerForgePotential = uint8((mergerEntropy / 10) % 10); // Extract the 5th digit from the entropy
    forgingCounts[mergerTokenId]++;
    require(
      mergerForgePotential > 0 &&
        forgingCounts[mergerTokenId] <= mergerForgePotential,
      'forgePotential insufficient'
    );

    uint256 devFee = forgingFee / taxCut;
    uint256 forgerShare = forgingFee - devFee;
    address payable forgerOwner = payable(nftContract.ownerOf(forgerTokenId));

    uint256 newTokenId = nftContract.forge(
      msg.sender,
      forgerTokenId,
      mergerTokenId,
      ''
    );
    (bool success, ) = nukeFundAddress.call{ value: devFee }('');
    require(success, 'Failed to send to NukeFund');
    (bool success_forge, ) = forgerOwner.call{ value: forgerShare }('');
    require(success_forge, 'Failed to send to Forge Owner');

    // Cancel listed forger nft
    _cancelListingForForging(forgerTokenId);

    uint256 newEntropy = nftContract.getTokenEntropy(newTokenId);

    emit EntityForged(
      newTokenId,
      forgerTokenId,
      mergerTokenId,
      newEntropy,
      forgingFee
    );

    return newTokenId;
  }

  function cancelListingForForging(
    uint256 tokenId
  ) external whenNotPaused nonReentrant {
    require(
      nftContract.ownerOf(tokenId) == msg.sender ||
        msg.sender == address(nftContract),
      'Caller must own the token'
    );
    require(
      listings[listedTokenIds[tokenId]].isListed,
      'Token not listed for forging'
    );

    _cancelListingForForging(tokenId);
  }

  function _cancelListingForForging(uint256 tokenId) internal {
    delete listings[listedTokenIds[tokenId]];

    emit CancelledListingForForging(tokenId); // Emitting with 0 fee to denote cancellation
  }

  function _resetForgingCountIfNeeded(uint256 tokenId) private {
    uint256 oneYear = oneYearInDays;
    if (lastForgeResetTimestamp[tokenId] == 0) {
      lastForgeResetTimestamp[tokenId] = block.timestamp;
    } else if (block.timestamp >= lastForgeResetTimestamp[tokenId] + oneYear) {
      forgingCounts[tokenId] = 0; // Reset to the forge potential
      lastForgeResetTimestamp[tokenId] = block.timestamp;
    }
  }
}
