// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

uint16 constant chunksCountX = 24;
uint16 constant chunksCountY = 24;
uint8 constant chunkPixelSize = 1;

interface ICanvas {
    function getChunk(uint8 x, uint8 y) external view returns (uint256);

    function setChunk(uint8 x, uint8 y, uint256 chunkData) external;

    function setChunkByIndex(uint16 chunkIndex, uint256 chunkData) external;

    function getChunks()
        external
        view
        returns (uint256[chunksCountX * chunksCountY] memory);

    function getBitmap() external view returns (string memory);
}
