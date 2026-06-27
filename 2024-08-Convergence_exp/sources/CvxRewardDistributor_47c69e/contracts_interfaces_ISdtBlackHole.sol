// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ICommonStruct.sol";

interface ISdtBlackHole {
    function withdraw(uint256 amount, address receiver) external;

    function setGaugeReceiver(address gaugeAddress, address bufferReceiver) external;

    function getBribeTokensForBuffer(address buffer) external view returns (IERC20[] memory);

    function pullSdStakingBribes(
        address _processor,
        uint256 _processorRewardsPercentage
    ) external returns (ICommonStruct.TokenAmount[] memory);
}
