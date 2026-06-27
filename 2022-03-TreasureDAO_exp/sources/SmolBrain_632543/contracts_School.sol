// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/access/Ownable.sol';
import './SmolBrain.sol';

contract School is Ownable {
    uint256 public constant WEEK = 7 days;
    /// @dev 18 decimals
    uint256 public iqPerWeek;
    /// @dev 18 decimals
    uint256 public totalIqStored;
    /// @dev unix timestamp
    uint256 public lastRewardTimestamp;
    uint256 public smolBrainSupply;

    SmolBrain public smolBrain;

    mapping(uint256 => uint256) public timestampJoined;

    event JoinSchool(uint256 tokenId);
    event DropSchool(uint256 tokenId);
    event SetIqPerWeek(uint256 iqPerWeek);
    event SmolBrainSet(address smolBrain);

    modifier onlySmolBrainOwner(uint256 _tokenId) {
        require(smolBrain.ownerOf(_tokenId) == msg.sender, "School: only owner can send to school");
        _;
    }

    modifier atSchool(uint256 _tokenId, bool expectedAtSchool) {
        require(isAtSchool(_tokenId) == expectedAtSchool, "School: wrong school attendance");
        _;
    }

    modifier updateTotalIQ(bool isJoining) {
        if (smolBrainSupply > 0) {
            totalIqStored = totalIQ();
        }
        lastRewardTimestamp = block.timestamp;
        isJoining ? smolBrainSupply++ : smolBrainSupply--;
        _;
    }

    function totalIQ() public view returns (uint256) {
        uint256 timeDelta = block.timestamp - lastRewardTimestamp;
        return totalIqStored + smolBrainSupply * iqPerWeek * timeDelta / WEEK;
    }

    function iqEarned(uint256 _tokenId) public view returns (uint256 iq) {
        if (timestampJoined[_tokenId] == 0) return 0;
        uint256 timedelta = block.timestamp - timestampJoined[_tokenId];
        iq = iqPerWeek * timedelta / WEEK;
    }

    function isAtSchool(uint256 _tokenId) public view returns (bool) {
        return timestampJoined[_tokenId] > 0;
    }

    function join(uint256 _tokenId)
        external
        onlySmolBrainOwner(_tokenId)
        atSchool(_tokenId, false)
        updateTotalIQ(true)
    {
        timestampJoined[_tokenId] = block.timestamp;
        emit JoinSchool(_tokenId);
    }

    function drop(uint256 _tokenId)
        external
        onlySmolBrainOwner(_tokenId)
        atSchool(_tokenId, true)
        updateTotalIQ(false)
    {
        smolBrain.schoolDrop(_tokenId, iqEarned(_tokenId));
        timestampJoined[_tokenId] = 0;
        emit DropSchool(_tokenId);
    }

    // ADMIN

    function setSmolBrain(address _smolBrain) external onlyOwner {
        smolBrain = SmolBrain(_smolBrain);
        emit SmolBrainSet(_smolBrain);
    }

    /// @param _iqPerWeek NUmber of IQ points to earn a week, 18 decimals
    function setIqPerWeek(uint256 _iqPerWeek) external onlyOwner {
        iqPerWeek = _iqPerWeek;
        emit SetIqPerWeek(_iqPerWeek);
    }
}
