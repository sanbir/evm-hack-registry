// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../LiquidTokenStakingPool.sol";

contract ImmediateLiquidTokenStakingPool is LiquidTokenStakingPool {
    /**
     * Events
     */
    event ImmediatelyDistributed(
        address indexed receiverAddress,
        uint256 amount
    );

    // reserve some gap for the future upgrades
    uint256[50] private __reserved;

    function __ImmediatePool_init() internal onlyInitializing {}

    /**
     * @notice Safe distribution
     * @dev Checks the result of _unsafeTransfer()
     */
    function _distributeRewards(address receiverAddress, uint256 amount)
        internal
    {
        require(
            getFreeBalance() >= amount,
            "LiquidTokenStakingPool: balance less than rewards amount"
        );
        bool result = _unsafeTransfer(receiverAddress, amount, false);
        require(
            result,
            "LiquidTokenStakingPool: failed to send rewards to claimer"
        );
        emit ImmediatelyDistributed(receiverAddress, amount);
    }
}
