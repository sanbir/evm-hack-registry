// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./ICanvas.sol";

abstract contract CanvasBounds {
    modifier inBounds(uint8 x, uint8 y) {
        require(x < chunksCountX, "position x out of bounds");
        require(y < chunksCountY, "position y out of bounds");
        _;
    }

    function getChunksCount() external pure returns (uint16 x, uint16 y) {
        return (chunksCountX, chunksCountY);
    }

    function chunkIndex(
        uint8 x,
        uint8 y
    ) public pure inBounds(x, y) returns (uint16) {
        return chunksCountX * y + x;
    }
}
