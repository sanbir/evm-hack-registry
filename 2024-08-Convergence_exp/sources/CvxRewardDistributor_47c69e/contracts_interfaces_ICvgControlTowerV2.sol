// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./IERC20Mintable.sol";
import "./ICvg.sol";
import "./IBondDepository.sol";
import "./IBondCalculator.sol";
import "./IBondStruct.sol";
import "./ICvgOracle.sol";
import "./IVotingPowerEscrow.sol";
import "./ICvgRewards.sol";
import "./ILockingPositionManager.sol";
import "./ILockingPositionDelegate.sol";
import "./IGaugeController.sol";
import "./IYsDistributor.sol";
import "./IBondPositionManager.sol";
import "./ISdtStakingPositionManager.sol";
import "./IBondLogo.sol";
import "./ILockingLogo.sol";
import "./ILockingPositionService.sol";
import "./IVestingCvg.sol";
import "./ISdtBuffer.sol";
import "./ISdtBlackHole.sol";
import "./ISdtStakingPositionService.sol";
import "./ISdtFeeCollector.sol";
import "./ISdtRewardDistributor.sol";
import "./Convex/ICvxStakingPositionService.sol";

import "./Convex/ICvxRewardDistributor.sol";
import "./Convex/ICvxStakingLogo.sol";

interface ICvgControlTowerV2 is ICvgControlTower {
    function convexTreasury() external view returns (address);
}
