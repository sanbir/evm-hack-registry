// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import './School.sol';
import './Land.sol';
import "./MinterControl.sol";

contract SmolBrain is MinterControl, ERC721Enumerable {
    using Strings for uint256;
    using Counters for Counters.Counter;

    uint256 constant LAST_MALE = 6710;
    uint256 constant LAST_FEMALE = 13421;

    enum Gender { Male, Female }

    Counters.Counter private _maleTokenIdTracker;
    Counters.Counter private _femaleTokenIdTracker;
    string public baseURI;

    /// @dev 18 decimals
    uint256 public brainMaxLevel;
    /// @dev 18 decimals
    uint256 public levelIQCost;

    School public school;
    Land public land;

    // tokenId => IQ
    mapping(uint256 => uint256) public brainz;

    event SmolBrainMint(address to, uint256 tokenId, Gender gender);
    event LevelIQCost(uint256 levelIQCost);
    event LandMaxLevel(uint256 brainMaxLevel);
    event SchoolSet(address school);
    event LandSet(address land);

    modifier onlySchool() {
        require(msg.sender == address(school), "SmolBrain: !school");
        _;
    }

    constructor(address _luckyWinner) ERC721("Smol Brain", "SmolBrain") {
        _femaleTokenIdTracker._value = LAST_MALE + 1;
        _mint(_luckyWinner, Gender.Male);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, AccessControl) returns (bool) {
        return ERC721Enumerable.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function mintMale(address _to) external onlyMinter {
        _mint(_to, Gender.Male);
    }

    function mintFemale(address _to) external onlyMinter {
        _mint(_to, Gender.Female);
    }

    function getGender(uint256 _tokenId) public pure returns (Gender) {
        return _tokenId <= LAST_MALE ? Gender.Male : Gender.Female;
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        require(_exists(_tokenId), "SmolBrain: URI query for nonexistent token");

        uint256 level = Math.min(scanBrain(_tokenId) / levelIQCost, brainMaxLevel);
        return bytes(baseURI).length > 0 ?
            string(abi.encodePacked(
                baseURI,
                _tokenId.toString(),
                "/",
                level.toString()
            ))
            : "";
    }

    function scanBrain(uint256 _tokenId) public view returns (uint256 IQ) {
        IQ = brainz[_tokenId] + school.iqEarned(_tokenId);
    }

    function averageIQ() public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 totalIQ = school.totalIQ();
        return totalIQ / totalSupply();
    }

    /// @param _tokenId tokenId of the land
    function schoolDrop(uint256 _tokenId, uint256 _iqEarned) external onlySchool {
        brainz[_tokenId] += _iqEarned;
    }

    function _mint(address _to, Gender _gender) internal {
        uint256 _tokenId;
        if (_gender == Gender.Male) {
            _tokenId = _maleTokenIdTracker.current();
            _maleTokenIdTracker.increment();
            require(_tokenId <= LAST_MALE, "SmolBrain: exceeded tokenId for male");
        } else {
            _tokenId = _femaleTokenIdTracker.current();
            _femaleTokenIdTracker.increment();
            require(_tokenId <= LAST_FEMALE, "SmolBrain: exceeded tokenId for female");
        }

        emit SmolBrainMint(_to, _tokenId, _gender);
        _safeMint(_to, _tokenId);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _tokenId
    ) internal override {
        super._beforeTokenTransfer(_from, _to, _tokenId);

        if (address(school) != address(0))
            require(!school.isAtSchool(_tokenId), "SmolBrain: is at school. Drop school to transfer.");
        if (_from != address(0))
            land.upgradeSafe(land.tokenOfOwnerByIndex(_from, 0));
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    // ADMIN

    function setSchool(address _school) external onlyOwner {
        school = School(_school);
        emit SchoolSet(_school);
    }

    function setLand(address _land) external onlyOwner {
        land = Land(_land);
        emit LandSet(_land);
    }

    function setLevelIQCost(uint256 _levelIQCost) external onlyOwner {
        levelIQCost = _levelIQCost;
        emit LevelIQCost(_levelIQCost);
    }

    function setMaxLevel(uint256 _brainMaxLevel) external onlyOwner {
        brainMaxLevel = _brainMaxLevel;
        emit LandMaxLevel(_brainMaxLevel);
    }

    function setBaseURI(string memory _baseURItoSet) external onlyOwner {
        baseURI = _baseURItoSet;
    }
}
