// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAbstractRewards.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

abstract contract AbstractRewards is IAbstractRewards {
  using SafeCast for uint128;
  using SafeCast for uint256;
  using SafeCast for int256;

  uint128 public constant SCALING_FACTOR = type(uint128).max;

  function(address) view returns (uint256) private immutable getAccountBalance;
  function() view returns (uint256) private immutable getTotalBalance;

  uint256 public shareBasedPoints;
  mapping(address => int256) public pointsCorrection;
  mapping(address => uint256) public withdrawnRewards;

    constructor(
        function(address) internal view returns (uint256) getAccountBalance_,
        function() internal view returns (uint256) getTotalBalance_
    ) {
        getAccountBalance = getAccountBalance_;
        getTotalBalance = getTotalBalance_;
    }

    function getRedeemablePayouts(address _account) public view override returns (uint256) {
        return getCumulativePayouts(_account) - withdrawnRewards[_account];
    }

    function getRedeemedPayouts(address _account) public view override returns (uint256) {
        return withdrawnRewards[_account];
    }

    function getCumulativePayouts(address _account) public view override returns (uint256) {
        return ((shareBasedPoints * getAccountBalance(_account)).toInt256() + pointsCorrection[_account]).toUint256() / SCALING_FACTOR;
    }

    function _distributeRewards(uint256 _amount) internal {
        uint256 totalShares = getTotalBalance();
        require(totalShares > 0, "AbstractRewards: total share supply is zero");

        if (_amount > 0) {
            shareBasedPoints = shareBasedPoints + (_amount * SCALING_FACTOR / totalShares);
            emit RewardsDistributed(msg.sender, _amount);
        }
    }

    function setupClaim(address _account) internal returns (uint256) {
        uint256 redeemableShare = getRedeemablePayouts(_account);
        if (redeemableShare > 0) {
            withdrawnRewards[_account] = withdrawnRewards[_account] + redeemableShare;
            emit RewardsWithdrawn(_account, redeemableShare);
        }
        return redeemableShare;
    }

    function adjustPointsForTransfer(address _from, address _to, uint256 _shares) internal {
        int256 magnitudeCorrection = (shareBasedPoints * _shares).toInt256();
        pointsCorrection[_from] = pointsCorrection[_from] + magnitudeCorrection;
        pointsCorrection[_to] = pointsCorrection[_to] - magnitudeCorrection;
    }

    function adjustPoints(address _account, int256 _shares) internal {
        pointsCorrection[_account] = pointsCorrection[_account] + (_shares * int256(shareBasedPoints));
    }
}