// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILockingPositionService {
    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        STORED STRUCTS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    struct LockingPosition {
        /// @dev Starting cycle of a LockingPosition. Maximum value of uint24 is 16M, so 16M weeks is way enough.
        uint24 startCycle;
        /// @dev End cycle of a LockingPosition. Maximum value of uint24 is 16M, so 16M weeks is way enough.
        uint24 lastEndCycle;
        /** @dev Percentage of the token allocated to ysCvg. Amount dedicated to vote is so equal to 100 - ysPercentage.
         *  A position with ysPercentage as 60 will allocate 60% of his locking to YsCvg and 40% to veCvg and mgCvg.
         */
        uint8 ysPercentage;
        /** @dev Total Cvg amount locked in the position.
         *  Max supply of CVG is 150M, it so fits into an uint104 (20 000 billions approx).
         */
        uint104 totalCvgLocked;
        /**  @dev MgCvgAmount held by the position.
         *   Max supply of mgCVG is 150M, it so fits into an uint96 (20 billions approx).
         */
        uint96 mgCvgAmount;
    }

    struct TrackingBalance {
        /** @dev Amount of ysCvg to add to the total supply when the corresponding cvgCycle is triggered.
         *  Max supply of ysCVG is 150M, it so fits into an uint128.
         */
        uint128 ysToAdd;
        /** @dev Amount of ysCvg to remove from the total supply when the corresponding cvgCycle is triggered.
         *  Max supply of ysCVG is 150M, it so fits into an uint128.
         */
        uint128 ysToSub;
    }

    struct Checkpoints {
        uint24 cycleId;
        uint232 ysBalance;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        VIEW STRUCTS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    struct TokenView {
        uint256 tokenId;
        uint128 startCycle;
        uint128 endCycle;
        uint256 cvgLocked;
        uint256 ysActual;
        uint256 ysTotal;
        uint256 veCvgActual;
        uint256 mgCvg;
        uint256 ysPercentage;
    }

    struct LockingInfo {
        uint256 tokenId;
        uint256 cvgLocked;
        uint256 lockEnd;
        uint256 ysPercentage;
        uint256 mgCvg;
    }

    function TDE_DURATION() external view returns (uint256);

    function MAX_LOCK() external view returns (uint24);

    function updateYsTotalSupply() external;

    function ysTotalSupplyHistory(uint256) external view returns (uint256);

    function ysShareOnTokenAtTde(uint256, uint256) external view returns (uint256);

    function veCvgVotingPowerPerAddress(address _user) external view returns (uint256);

    function mintPosition(
        uint24 lockDuration,
        uint128 amount,
        uint8 ysPercentage,
        address receiver,
        bool isAddToManagedTokens
    ) external;

    function increaseLockAmount(uint256 tokenId, uint128 amount, address operator) external;

    function increaseLockTime(uint256 tokenId, uint256 durationAdd) external;

    function increaseLockTimeAndAmount(uint256 tokenId, uint24 durationAdd, uint128 amount, address operator) external;

    function totalSupplyYsCvgHistories(uint256 cycleClaimed) external view returns (uint256);

    function balanceOfYsCvgAt(uint256 tokenId, uint256 cycle) external view returns (uint256);

    function lockingPositions(uint256 tokenId) external view returns (LockingPosition memory);

    function unlockingTimestampPerToken(uint256 tokenId) external view returns (uint256);

    function lockingInfo(uint256 tokenId) external view returns (LockingInfo memory);

    function isContractLocker(address contractAddress) external view returns (bool);

    function getTotalSupplyAtAndBalanceOfYs(uint256 tokenId, uint256 cycleId) external view returns (uint256, uint256);

    function getTotalSupplyHistoryAndBalanceOfYs(
        uint256 tokenId,
        uint256 cycleId
    ) external view returns (uint256, uint256);
}
