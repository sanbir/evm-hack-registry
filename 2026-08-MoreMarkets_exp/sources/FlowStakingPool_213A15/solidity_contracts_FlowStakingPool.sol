// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@ankr.com/contracts/earn/extension/MixedLiquidTokenStakingPool.sol";
import "./config/FlowStakingConfig.sol";

contract FlowStakingPool is MixedLiquidTokenStakingPool {
    event FlowBridgeAddressChanged(address prevValue, address newValue);
    event FlowBridgeFunded(address bridge, uint256 amount);

    /// @dev Cadence-owned account address. Used to bridge staked FLOW to Cadence side
    address internal flowBridgeAddress;

    /// @param earnConfig contains major addresses for Ankr LiquidTokenStaking: consensus, governance, treasury...
    function initialize(
        IEarnConfig earnConfig,
        uint256 distributeGasLimit,
        address _flowBridgeAddress
    ) external initializer {
        require(
            _flowBridgeAddress != address(0),
            "Cannot set Flow bridge address to zero"
        );
        __Ownable_init();
        __QueuePool_init(distributeGasLimit);
        __LiquidTokenStakingPool_init(earnConfig);
        __ReferralPool_init();
        __ImmediatePool_init();
        __ManualClaimPool_init();
        __MixedPool_init();
        flowBridgeAddress = _flowBridgeAddress;
        emit FlowBridgeAddressChanged(address(0), _flowBridgeAddress);
    }

    /**
     * Staking methods
     */

    /// @dev After staking, we need to send funds to the flow bridge
    function _afterStake(
        address /* account */,
        uint256 amount,
        uint256 /* shares */
    ) internal virtual override {
        bool bridgeTransfer = _unsafeTransfer(flowBridgeAddress, amount, false);
        require(
            bridgeTransfer,
            "FlowStakingPool: failed to send staked FLOW to bridge address"
        );

        emit FlowBridgeFunded(flowBridgeAddress, amount);
    }

    /**
     * Unstaking methods
     */

    /// @dev Everyone can execute, but usually a backend service do it
    /// @notice Pending unstake requests kept in smart-contract state with receive addresses
    /// @dev GasLimit param should be set higher than 100_000 wei for execution queue in _distributePendingRewards
    function distributePendingRewards() external payable nonReentrant {
        _distributePendingRewards();
    }

    /**
     * FlowEVMPool specific methods
     */
    // TODO: determine necesity of checking newValue COA ownership
    function setFlowBridgeAddress(address newValue) external onlyOwner {
        require(
            newValue != address(0),
            "Cannot set Flow bridge address to zero"
        );
        address prevValue = flowBridgeAddress;
        flowBridgeAddress = newValue;
        emit FlowBridgeAddressChanged(prevValue, newValue);
    }

    function getFlowBridgeAddress() external view returns (address) {
        return flowBridgeAddress;
    }

    /// @notice Recovers native FLOW held by this contract that is not owed to any
    /// pending unstake request or manual claim - e.g. FLOW sent here directly
    /// (bypassing stakeBonds/stakeCerts) by mistake. Always routed to
    /// flowBridgeAddress, the same destination staked funds are forwarded to.
    /// @dev Bounded by getFreeBalance() - getTotalPendingUnstakes(), so funds
    /// reserved for other users' unstakes/manual claims can never be moved.
    function recoverStrayFunds(
        uint256 amount
    ) external onlyOwner nonReentrant {
        uint256 pendingUnstakes = getTotalPendingUnstakes();
        uint256 freeBalance = getFreeBalance();
        require(
            freeBalance > pendingUnstakes,
            "FlowStakingPool: no recoverable surplus"
        );
        uint256 surplus = freeBalance - pendingUnstakes;
        require(
            amount <= surplus,
            "FlowStakingPool: amount exceeds recoverable surplus"
        );

        bool success = _unsafeTransfer(flowBridgeAddress, amount, false);
        require(success, "FlowStakingPool: transfer failed");

        emit FlowBridgeFunded(flowBridgeAddress, amount);
    }
}
