// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../ICommonStruct.sol";
import "./ICvxAssetStakerBuffer.sol";
import "./ICvxAssetWrapper.sol";
import "../ICrvPoolPlain.sol";
interface ICvxStakingPositionService {
    struct CycleInfo {
        uint256 cvgRewardsAmount;
        uint256 totalStaked;
        bool isCvxProcessed;
    }

    struct AccountInfos {
        uint256 amountStaked;
        uint256 pendingStaked;
    }
    struct CycleInfoMultiple {
        uint256 totalStaked;
        ICommonStruct.TokenAmount[] cvxClaimable;
    }
    struct StakingInfo {
        address account;
        string symbol;
        uint256 pending;
        uint256 totalStaked;
        uint256 cvgClaimable;
        ICommonStruct.TokenAmount[] cvxClaimable;
    }

    function setBuffer(address _buffer) external;

    function symbol() external view returns (string memory);

    function stakingCycle() external view returns (uint256);

    function cycleInfo(uint256 cycleId) external view returns (CycleInfo memory);

    function cvxAsset() external view returns (IERC20Metadata);

    function cvxAssetWrapper() external view returns (ICvxAssetWrapper);

    function buffer() external view returns (ICvxAssetStakerBuffer);

    function accountTotalStaked(address account) external view returns (uint256 amount);

    function stakedAmountEligibleAtCycle(
        uint256 cvgCycle,
        uint256 tokenId,
        uint256 actualCycle
    ) external view returns (uint256);

    function accountInfoByCycle(uint256 cycleId, address account) external view returns (AccountInfos memory);

    function stakingInfo(address account) external view returns (StakingInfo memory);

    function getProcessedCvxRewards(uint256 _cycleId) external view returns (ICommonStruct.TokenAmount[] memory);

    function deposit(uint256 amount, address operator) external;

    function claimCvgCvxMultiple(address account) external returns (uint256, ICommonStruct.TokenAmount[] memory);

    function asset() external view returns (IERC20);

    function curvePool() external view returns (ICrvPoolPlain);
}
