// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ICommonStruct.sol";

interface ISdtRewardDistributor {
    function claimCvgSdtSimple(
        address receiver,
        uint256 cvgAmount,
        ICommonStruct.TokenAmount[] memory sdtRewards,
        uint256 minCvgSdtAmountOut,
        bool isConvert
    ) external;
}
