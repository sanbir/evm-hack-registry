// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface IVault {
    error AccessControlBadConfirmation();
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error ReentrancyGuardReentrantCall();
    error SafeERC20FailedOperation(address token);

    event AddingStableCoin(
        uint256 lockTime,
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    );
    event BlockedCollateralRemoval(address stablecoin, address user, uint256 amount);
    event ChangedRatioLockTime(uint256 newRatioLockTime);
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MOD_ROLE() external view returns (bytes32);
    function PERP_PAIR_ROLE() external view returns (bytes32);
    function _setTotalCollateral(uint256 amount) external;
    function addCollateral(uint256[] memory collateral) external;
    function addPnlToCollateral(address user, uint256 pnl, bool pnlSign) external;
    function addStableCoin(
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    ) external;
    function addStableHash() external view returns (bytes32);
    function addStableTimeLock() external view returns (uint256);
    function addStableTimeLockDuration() external view returns (uint256);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function getUserCollaterals(address user) external view returns (uint256[] memory collateral);
    function getUserTotalCollateral(address user) external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function initializeParameters(address _perpPairAddress, address _lostAndFoundAddress) external;
    function isTrustedForwarder(address forwarder) external view returns (bool);
    function lastSnapshotTimestamp() external view returns (uint256);
    function lostAndFound() external view returns (address);
    function oracle() external view returns (address);
    function minCollateralMovement() external view returns (uint256);
    function modifyDepositRatioThresholds(address stableCoin, uint256 depositRatioThreshold) external;
    function modifyRatioLockTime(uint256 _ratioLockTime) external;
    function modifyWithdrawalRatioThreshold(address stableCoin, uint256 withdrawalRatioThreshold) external;
    function perpPair() external view returns (address);
    function prepareAddStableCoin(
        address stableCoin,
        uint256 depositRatioThreshold,
        uint256 withdrawalRatioThreshold,
        uint256 stableDecimals,
        uint256 newTimeLockDuration
    ) external;
    function ratiosSnapshot(uint256) external view returns (uint256);
    function removeAllCollateral(bytes memory unverifiedReport) external;
    function removeAllCollateralForUser(address user) external;
    function removeCollateral(uint256 amount, bytes memory unverifiedReport) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function revokeRole(bytes32 role, address account) external;
    function stableCoins(uint256)
        external
        view
        returns (
            address stableCoin,
            uint256 depositRatioThreshold,
            uint256 withdrawalRatioThreshold,
            uint256 stableDecimals
        );
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function totalCollateral() external view returns (uint256);
    function totalCollateralRatio(address) external view returns (uint256);
    function trustedForwarder() external view returns (address);
    function userCollateral(address) external view returns (uint256);
    function userCollateralRatio(address, address) external view returns (uint256);
}
