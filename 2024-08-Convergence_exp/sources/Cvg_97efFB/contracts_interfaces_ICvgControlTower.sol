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
import "./ISdtBuffer.sol";
import "./ISdtRewardDistributor.sol";

interface ICvgControlTower {
    function cvgToken() external view returns (ICvg);

    function cvgOracle() external view returns (ICvgOracle);

    function bondCalculator() external view returns (IBondCalculator);

    function gaugeController() external view returns (IGaugeController);

    function cvgCycle() external view returns (uint128);

    function votingPowerEscrow() external view returns (IVotingPowerEscrow);

    function treasuryDao() external view returns (address);

    function treasuryPod() external view returns (address);

    function treasuryPdd() external view returns (address);

    function treasuryAirdrop() external view returns (address);

    function treasuryTeam() external view returns (address);

    function cvgRewards() external view returns (ICvgRewards);

    function lockingPositionManager() external view returns (ILockingPositionManager);

    function lockingPositionService() external view returns (ILockingPositionService);

    function lockingPositionDelegate() external view returns (ILockingPositionDelegate);

    function isStakingContract(address contractAddress) external view returns (bool);

    function ysDistributor() external view returns (IYsDistributor);

    function isBond(address account) external view returns (bool);

    function bondPositionManager() external view returns (IBondPositionManager);

    function sdtStakingPositionManager() external view returns (ISdtStakingPositionManager);

    function sdtStakingLogo() external view returns (ISdtStakingLogo);

    function bondLogo() external view returns (IBondLogo);

    function lockingLogo() external view returns (ILockingLogo);

    function isSdtStaking(address contractAddress) external view returns (bool);

    function vestingCvg() external view returns (IVestingCvg);

    function sdt() external view returns (IERC20);

    function cvgSDT() external view returns (IERC20Mintable);

    function cvgSdtStaking() external view returns (ISdtStakingPositionService);

    function cvgSdtBuffer() external view returns (ISdtBuffer);

    function veSdtMultisig() external view returns (address);

    function cloneFactory() external view returns (address);

    function sdtUtilities() external view returns (address);

    function insertNewSdtStaking(address _sdtStakingClone) external;

    function allBaseSdAssetStaking(uint256 _index) external view returns (address);

    function allBaseSdAssetBuffer(uint256 _index) external view returns (address);

    function sdtFeeCollector() external view returns (ISdtFeeCollector);

    function updateCvgCycle() external;

    function sdtBlackHole() external view returns (ISdtBlackHole);

    function sdtRewardDistributor() external view returns (address);

    function poolCvgSdt() external view returns (address);

    function bondDepository() external view returns (address);
}
