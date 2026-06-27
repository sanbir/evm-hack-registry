// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RWAEvents
/// @notice Event definitions for YieldCore RWA contracts (Fixed-term vaults)
library RWAEvents {
    // ============ Factory Events ============
    event VaultCreated(
        address indexed vault,
        address indexed creator,
        string name,
        string symbol,
        uint256 termDuration,
        uint256 fixedAPY,
        uint256 timestamp
    );

    event VaultDeactivated(address indexed vault, uint256 timestamp);
    event VaultReactivated(address indexed vault, uint256 timestamp);

    // ============ Vault Events ============
    event CapitalDeployed(address indexed vault, uint256 amount, address indexed recipient);
    event CapitalReturned(address indexed vault, uint256 amount, address indexed sender);
    event LossRecorded(address indexed vault, uint256 amount);

    // ============ Loan Events ============
    event LoanRegistered(uint256 indexed loanId, address indexed vault, bytes32 indexed borrowerId);
    event LoanUpdated(uint256 indexed loanId, uint256 repaidAmount, uint256 interestAmount);

    event LoanCreated(
        uint256 indexed loanId,
        address indexed vault,
        bytes32 indexed borrowerId,
        uint256 principal,
        uint256 interestRate,
        uint256 term,
        uint256 collateralValue
    );

    event RepaymentRecorded(
        uint256 indexed loanId,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 protocolFee,
        uint256 remainingPrincipal
    );

    event LoanStatusUpdated(uint256 indexed loanId, uint8 newStatus);

    // ============ Pool Manager Events ============
    event VaultRegistered(address indexed vault);
    event VaultUnregistered(address indexed vault);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesWithdrawn(address indexed treasury, uint256 amount);

    // ============ Registry Events ============
    event VaultAdded(address indexed vault, string name, uint256 termDuration);
    event VaultRemoved(address indexed vault);
    event VaultStatusChanged(address indexed vault, bool active);

    // ============ Emergency Events ============
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    // ============ Deployment Timelock Events ============
    event DeploymentAnnounced(uint256 indexed deploymentId, uint256 amount, address indexed recipient, uint256 executeTime);
    event DeploymentExecuted(uint256 indexed deploymentId, uint256 amount, address indexed recipient);
    event DeploymentCancelled(uint256 indexed deploymentId);
}
