// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./IPresaleCvgSeed.sol";

interface IVestingCvg {
    /// @dev Struct Info about VestingSchedules
    struct VestingSchedule {
        uint16 daysBeforeCliff;
        uint16 daysAfterCliff;
        uint24 dropCliff;
        uint256 totalAmount;
        uint256 totalReleased;
    }

    struct InfoVestingTokenId {
        uint256 amountReleasable;
        uint256 totalCvg;
        uint256 amountRedeemed;
    }

    enum VestingType {
        SEED,
        WL,
        IBO,
        TEAM,
        DAO
    }

    function vestingSchedules(VestingType vestingType) external view returns (VestingSchedule memory);

    function getInfoVestingTokenId(
        uint256 _tokenId,
        VestingType vestingType
    ) external view returns (InfoVestingTokenId memory);

    function whitelistedTeam() external view returns (address);

    function presaleSeed() external view returns (IPresaleCvgSeed);

    function MAX_SUPPLY_TEAM() external view returns (uint256);

    function startTimestamp() external view returns (uint256);
}
