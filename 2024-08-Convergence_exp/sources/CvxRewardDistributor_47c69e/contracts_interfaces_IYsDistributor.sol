// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ICommonStruct.sol";

interface IYsDistributor {
    struct TokenAmount {
        IERC20 token;
        uint96 amount;
    }

    struct Claim {
        uint256 tdeCycle;
        bool isClaimed;
        TokenAmount[] tokenAmounts;
    }

    function getRewardsForPosition(uint256 _tokenId) external view returns (ICommonStruct.TokenAmount[] memory);

    function getPositionRewardsForTdes(
        uint256[] calldata _tdeIds,
        uint256 actualCycle,
        uint256 _tokenId
    ) external view returns (Claim[] memory);

    function getAllRewardsForTde() external view returns (ICommonStruct.TokenAmount[] memory);
}
