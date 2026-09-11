// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../LiquidTokenStakingPool.sol";
import "./ManualClaimLiquidTokenStakingPool.sol";
import "./QueueLiquidTokenStakingPool.sol";
import "./ImmediateLiquidTokenStakingPool.sol";
import "./ReferralLiquidTokenStakingPool.sol";

contract MixedLiquidTokenStakingPool is
    QueueLiquidTokenStakingPool,
    ImmediateLiquidTokenStakingPool,
    ReferralLiquidTokenStakingPool
{
    // reserve some gap for the future upgrades
    uint256[50] private __reserved;

    function __MixedPool_init() internal onlyInitializing {}

    /**
     * @dev Checks the receiverAddress for existing manual requests
     * @dev Might be overridden
     */
    function _beforeUnstake(
        address /* ownerAddress */,
        address receiverAddress,
        uint256 /* amount */
    )
        internal
        virtual
        override(LiquidTokenStakingPool, ManualClaimLiquidTokenStakingPool)
    {
        require(
            !isMarkedForManualClaim(receiverAddress),
            "LiquidTokenStakingPool: receiver is marked for manual claim"
        );
    }

    /**
     * @dev Checks the pool balance and then sends the amount immediately
     * @dev If the pool balance is less than the amount puts into the queue
     * @dev Might be overridden
     */
    function _afterUnstake(
        address ownerAddress,
        address receiverAddress,
        uint256 amount
    ) internal virtual override {
        // unstake immediately
        if (getFreeBalance() >= amount) {
            _distributeRewards(receiverAddress, amount);
            return;
        }
        // pending unstake
        _addIntoQueue(ownerAddress, receiverAddress, amount);
    }

    /**
     * @dev Might be overridden
     */
    function getFreeBalance()
        public
        view
        virtual
        override(ManualClaimLiquidTokenStakingPool, LiquidTokenStakingPool)
        returns (uint256)
    {
        return
            address(this).balance < getStashedForManualClaims()
                ? 0
                : address(this).balance - getStashedForManualClaims();
    }
}
