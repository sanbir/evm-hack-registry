// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import './SmolBrain.sol';
import "./MinterControl.sol";

contract Land is MinterControl, ERC721Enumerable {
    using Strings for uint256;
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdTracker;
    string public baseURI;

    /// @dev 18 decimals
    uint256 public landMaxLevel;
    /// @dev 18 decimals
    uint256 public levelIQCost;

    /// @dev tokenId => land level
    mapping(uint256 => uint256) public landLevels;

    SmolBrain public smolBrain;

    event LandMint(address indexed to, uint256 tokenId);
    event LandUpgrade(uint256 indexed tokenId, uint256 availableLevel);
    event LandMaxLevel(uint256 landMaxLevel);
    event LevelIQCost(uint256 levelIQCost);
    event SmolBrainSet(address smolBrain);

    constructor() ERC721("Smol Brain Land", "SmolBrainLand") {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, AccessControl) returns (bool) {
        return ERC721Enumerable.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function mint(address _to) external onlyMinter {
        emit LandMint(_to, _tokenIdTracker.current());

        _safeMint(_to, _tokenIdTracker.current());
        _tokenIdTracker.increment();
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        require(_exists(_tokenId), "Land: URI query for nonexistent token");

        (, uint256 availableLevel) = canUpgrade(_tokenId);
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, availableLevel.toString())) : "";
    }

    /// @param _tokenId tokenId of the land
    /// @return isUpgradeAvailable true if higher level is available
    /// @return availableLevel what level can land be upgraded to
    function canUpgrade(uint256 _tokenId) public view returns (bool isUpgradeAvailable, uint256 availableLevel) {
        uint256 highestIQ = findBiggestBrainIQ(ownerOf(_tokenId));
        uint256 averageIQ = smolBrain.averageIQ();
        uint256 maxLevel = Math.min(averageIQ / levelIQCost, landMaxLevel);
        availableLevel = Math.min(highestIQ / levelIQCost, maxLevel);
        uint256 storedLevel = landLevels[_tokenId];
        if (storedLevel < availableLevel) {
            isUpgradeAvailable = true;
        }
    }

    /// @param _owner owner of the land
    /// @return highestIQ IQ of the biggest brain
    function findBiggestBrainIQ(address _owner) public view returns (uint256 highestIQ) {
        uint256 length = smolBrain.balanceOf(_owner);

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = smolBrain.tokenOfOwnerByIndex(_owner, i);
            uint256 IQ = smolBrain.scanBrain(tokenId);
            if (IQ > highestIQ) {
                highestIQ = IQ;
            }
        }
    }

    /// @param _tokenId tokenId of the land
    function upgrade(uint256 _tokenId) external {
        require(upgradeSafe(_tokenId), "Land: nothing to upgrade");
    }

    function upgradeSafe(uint256 _tokenId) public returns (bool) {
        (bool isUpgradeAvailable, uint256 availableLevel) = canUpgrade(_tokenId);
        if (isUpgradeAvailable) {
            landLevels[_tokenId] = availableLevel;
            emit LandUpgrade(_tokenId, availableLevel);
        }
        return isUpgradeAvailable;
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _tokenId
    ) internal override {
        super._beforeTokenTransfer(_from, _to, _tokenId);

        require(balanceOf(_to) == 0, "Land: can own only one land");
        if (_from != address(0)) upgradeSafe(_tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    // ADMIN

    function setSmolBrain(address _smolBrain) external onlyOwner {
        smolBrain = SmolBrain(_smolBrain);
        emit SmolBrainSet(_smolBrain);
    }

    function setMaxLevel(uint256 _landMaxLevel) external onlyOwner {
        landMaxLevel = _landMaxLevel;
        emit LandMaxLevel(_landMaxLevel);
    }

    function setLevelIQCost(uint256 _levelIQCost) external onlyOwner {
        levelIQCost = _levelIQCost;
        emit LevelIQCost(_levelIQCost);
    }

    function setBaseURI(string memory _baseURItoSet) external onlyOwner {
        baseURI = _baseURItoSet;
    }
}
