// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./ManualClaimLiquidTokenStakingPool.sol";
import "../../interfaces/IQueueLiquidTokenStakingPool.sol";

contract QueueLiquidTokenStakingPool is
    ManualClaimLiquidTokenStakingPool,
    IQueueLiquidTokenStakingPool
{
    uint256 internal _DISTRIBUTE_GAS_LIMIT;

    uint256 internal _pendingGap;

    uint256 internal _pendingTotalUnstakes;
    address[] internal _pendingClaimers;
    mapping(address => uint256) internal _pendingClaimerUnstakes;

    uint256[] internal _pendingRequests;

    // reserve some gap for the future upgrades
    uint256[50 - 6] private __reserved;

    function __QueuePool_init(
        uint256 distributeGasLimit
    ) internal onlyInitializing {
        _DISTRIBUTE_GAS_LIMIT = distributeGasLimit;
        emit DistributeGasLimitChanged(0, distributeGasLimit);
    }

    function setDistributeGasLimit(uint256 newValue) external onlyGovernance {
        uint256 prevValue = _DISTRIBUTE_GAS_LIMIT;
        _DISTRIBUTE_GAS_LIMIT = newValue;

        emit DistributeGasLimitChanged(prevValue, newValue);
    }

    function getDistributeGasLimit() public view returns (uint256) {
        return _DISTRIBUTE_GAS_LIMIT;
    }

    function _addIntoQueue(
        address owner,
        address claimer,
        uint256 amount
    ) internal {
        require(
            amount != 0 && claimer != address(0),
            "LiquidTokenStakingPool: zero input values"
        );
        // each new request is placed at the end of the queue
        _pendingTotalUnstakes += amount;
        _pendingClaimers.push(claimer);
        _pendingRequests.push(amount);
        _pendingClaimerUnstakes[claimer] += amount;
        emit PendingUnstake(owner, claimer, amount);
    }

    function _distributePendingRewards() internal {
        require(
            _DISTRIBUTE_GAS_LIMIT > 0,
            "LiquidTokenStakingPool: DISTRIBUTE_GAS_LIMIT is not set"
        );
        uint256 poolBalance = getFreeBalance();
        address[] memory claimers = new address[](
            _pendingClaimers.length - _pendingGap
        );
        uint256[] memory amounts = new uint256[](
            _pendingClaimers.length - _pendingGap
        );
        uint256 j = 0;
        uint256 i = _pendingGap;

        while (
            i < _pendingClaimers.length &&
            poolBalance > 0 &&
            gasleft() > _DISTRIBUTE_GAS_LIMIT
        ) {
            address claimer = _pendingClaimers[i];
            uint256 toDistribute = _pendingRequests[i];
            if (claimer == address(0) || toDistribute == 0) {
                ++i;
                continue;
            }

            if (poolBalance < toDistribute) {
                break;
            }

            _pendingClaimerUnstakes[claimer] -= toDistribute;
            _pendingTotalUnstakes -= toDistribute;
            poolBalance -= toDistribute;
            delete _pendingClaimers[i];
            delete _pendingRequests[i];
            ++i;
            // if claimer for manual claim then add the request like manual
            if (isMarkedForManualClaim(claimer)) {
                _setForManualClaim(claimer, toDistribute);
                continue;
            }

            bool success = _unsafeTransfer(claimer, toDistribute, true);
            if (!success) {
                _setForManualClaim(claimer, toDistribute);
                continue;
            }
            claimers[j] = claimer;
            amounts[j] = toDistribute;
            ++j;
        }
        _pendingGap = i;
        /* decrease arrays */
        uint256 removeCells = claimers.length - j;
        if (removeCells > 0) {
            assembly {
                mstore(claimers, j)
            }
            assembly {
                mstore(amounts, j)
            }
        }

        emit RewardsDistributed(claimers, amounts);
    }

    function getTotalPendingUnstakes() public view returns (uint256) {
        return _pendingTotalUnstakes;
    }

    function getPendingRequestsOf(
        address claimer
    ) public view returns (uint256[] memory) {
        uint256 j;
        uint256[] memory unstakes = new uint256[](
            _pendingClaimers.length - _pendingGap
        );
        for (uint256 i = _pendingGap; i < _pendingClaimers.length; i++) {
            if (_pendingClaimers[i] == claimer) {
                unstakes[j] = _pendingRequests[i];
                ++j;
            }
        }
        uint256 removeCells = unstakes.length - j;
        if (removeCells > 0) {
            assembly {
                mstore(unstakes, j)
            }
        }
        return unstakes;
    }

    function getPendingUnstakesOf(
        address claimer
    ) public view returns (uint256) {
        return _pendingClaimerUnstakes[claimer];
    }
}
