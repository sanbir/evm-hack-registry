// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
}
