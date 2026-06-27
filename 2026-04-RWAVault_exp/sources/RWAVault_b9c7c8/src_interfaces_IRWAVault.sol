// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IRWAVault
/// @notice Interface for the RWA Vault contract (Fixed-term with monthly interest)
interface IRWAVault is IERC4626 {
    // ============ Enums ============

    enum Phase {
        Collecting,     // Collection period - user deposits allowed
        Active,         // Active period - deposits closed, interest accrues
        Matured,        // Maturity - principal + interest withdrawal allowed
        Defaulted       // Default - early termination, principal + accrued interest withdrawal
    }

    // ============ Initializer ============

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 collectionStartTime_,
        uint256 collectionEndTime_,
        uint256 interestStartTime_,
        uint256 termDuration_,
        uint256 fixedAPY_,
        uint256 minDeposit_,
        uint256 maxCapacity_,
        address poolManager_,
        address admin_
    ) external;

    // ============ Events ============

    event PhaseChanged(Phase oldPhase, Phase newPhase);
    event InterestClaimed(address indexed user, uint256 amount, uint256 month);
    event CapitalDeployed(uint256 amount, address indexed recipient);
    event CapitalReturned(uint256 amount, address indexed from);
    event InterestDeposited(uint256 amount);
    event VaultDefaulted(uint256 defaultTime);

    // ============ Interest Functions ============

    function claimInterest() external;
    function claimSingleMonth() external;
    function getClaimableMonths(address user) external view returns (uint256);
    function getPendingInterest(address user) external view returns (uint256);
    function getDepositInfo(address user) external view returns (
        uint256 shares,
        uint256 principal,
        uint256 lastClaimMonth,
        uint256 depositTime
    );

    // ============ Phase Management ============

    function activateVault() external;
    function matureVault() external;
    function triggerDefault() external;
    function setInterestStartTime(uint256 newTime) external;
    function setInterestPeriodEndDates(uint256[] calldata periodEndDates) external;
    function setInterestPaymentDates(uint256[] calldata paymentDates) external;
    function setWithdrawalStartTime(uint256 startTime) external;

    // ============ Pool Manager Functions ============

    function announceDeployCapital(uint256 amount, address recipient) external;
    function executeDeployCapital() external;
    function cancelDeployCapital() external;
    function returnCapital(uint256 amount) external;
    function depositInterest(uint256 amount) external;
    function recoverERC20(address token, uint256 amount, address recipient) external;
    function recoverAssetDust(address recipient) external;
    function recoverUnclaimedFunds(address recipient) external;
    function recoverETH(address payable recipient) external;

    // ============ View Functions ============

    function currentPhase() external view returns (Phase);
    function collectionStartTime() external view returns (uint256);
    function collectionEndTime() external view returns (uint256);
    function interestStartTime() external view returns (uint256);
    function maturityTime() external view returns (uint256);
    function termDuration() external view returns (uint256);
    function fixedAPY() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function maxCapacity() external view returns (uint256);
    function totalDeployed() external view returns (uint256);
    function totalInterestPaid() external view returns (uint256);
    function poolManager() external view returns (address);
    function availableLiquidity() external view returns (uint256);
    function isActive() external view returns (bool);
    function defaultTime() external view returns (uint256);

    function getVaultStatus() external view returns (
        Phase phase,
        uint256 totalAssets_,
        uint256 totalDeployed_,
        uint256 availableBalance,
        uint256 totalInterestPaid_
    );

    function getVaultConfig() external view returns (
        uint256 collectionEndTime_,
        uint256 interestStartTime_,
        uint256 maturityTime_,
        uint256 termDuration_,
        uint256 fixedAPY_,
        uint256 minDeposit_,
        uint256 maxCapacity_
    );

    // ============ Admin Functions ============

    function setActive(bool active_) external;
}
