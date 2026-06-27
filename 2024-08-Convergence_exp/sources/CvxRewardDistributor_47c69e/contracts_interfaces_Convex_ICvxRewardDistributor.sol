// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../ICommonStruct.sol";
import "./ICvxStakingPositionService.sol";
interface ICvxRewardDistributor {
    function claimCvgCvxSimple(
        address receiver,
        uint256 cvgAmount,
        ICommonStruct.TokenAmount[] memory cvxRewards,
        uint256 minCvgCvxAmountOut,
        bool isConvert
    ) external;
}
