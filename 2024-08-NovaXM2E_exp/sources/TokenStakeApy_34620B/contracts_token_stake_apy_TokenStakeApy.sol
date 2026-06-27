// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./ITokenStakeApy.sol";
import "../data/StructData.sol";

contract TokenStakeApy is ITokenStakeApy, Ownable, ERC721Holder {
    // mapping to store reward NFT Tier ean per day
    mapping(uint256 => uint256[]) public startTime;

    mapping(uint256 => uint256[]) public endTime;

    mapping(uint256 => uint256[]) public poolApy;

    constructor() {
        initNftApy();
    }

    /**
     * @dev init stake apr for each NFT ID
     */
    function initNftApy() internal {
        startTime[0] = [0];
        endTime[0] = [0];
        poolApy[0] = [8000];
        startTime[1] = [0];
        endTime[1] = [0];
        poolApy[1] = [12000];
        startTime[2] = [0];
        endTime[2] = [0];
        poolApy[2] = [24000];
        startTime[3] = [0];
        endTime[3] = [0];
        poolApy[3] = [36000];
        startTime[4] = [0, 1712731982];
        endTime[4] = [1712731982, 0];
        poolApy[4] = [60000, 96000];
        startTime[5] = [0, 1712731982];
        endTime[5] = [1712731982, 0];
        poolApy[5] = [84000, 144000];
    }

    function getStartTime(uint256 _poolId) external view override returns (uint256[] memory) {
        return startTime[_poolId];
    }

    function getEndTime(uint256 _poolId) external view override returns (uint256[] memory) {
        return endTime[_poolId];
    }

    function getPoolApy(uint256 _poolId) external view override returns (uint256[] memory) {
        return poolApy[_poolId];
    }

    function getMaxIndex(uint256 _poolId) external view override returns (uint256) {
        return poolApy[_poolId].length;
    }

    /**
     * @dev function to set stake apr for NFT ID
     * @param _poolId NFT ID
     * @param _apy apy of pool * 1000
     */
    function setNftApy(uint256 _poolId, uint256 _apy) external override onlyOwner {
        startTime[_poolId].push(block.timestamp);
        endTime[_poolId].pop();
        endTime[_poolId].push(block.timestamp);
        endTime[_poolId].push(0);
        poolApy[_poolId].push(_apy);
    }

    function setNftApyExactly(
        uint256 _poolId,
        uint256[] calldata _startTime,
        uint256[] calldata _endTime,
        uint256[] calldata _apy
    ) external override onlyOwner {
        startTime[_poolId] = _startTime;
        endTime[_poolId] = _endTime;
        poolApy[_poolId] = _apy;
    }
}
