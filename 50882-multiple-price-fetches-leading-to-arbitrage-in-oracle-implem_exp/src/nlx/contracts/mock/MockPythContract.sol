// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract MockPythContract is MockPyth {
    constructor() MockPyth(60, 1) {}

    function getPriceUpdateData(bytes32[] memory ids, int64[] memory prices) public view returns (bytes[] memory) {
        bytes[] memory updateData = new bytes[](ids.length);
        uint timestamp = block.timestamp;

        for (uint256 i = 0; i < ids.length; i++) {
            updateData[i] = createPriceFeedUpdateData(
                ids[i],
                prices[i] * 100000,
                10 * 100000,
                -5,
                prices[i] * 100000,
                10 * 100000,
                uint64(timestamp),
                uint64(timestamp - 60)
            );
        }

        return updateData;
    }
}

