// SPDX-License-Identifier: UNLCIENSED

pragma solidity >=0.8.0;

import {Side} from "../interfaces/IPool.sol";
import {SignedInt, SignedIntOps} from "./SignedInt.sol";
import {SafeCast} from "../lib/SafeCast.sol";

library PositionUtils {
    using SafeCast for uint256;
    using SignedIntOps for int256;

    function calcPnl(Side _side, uint256 _positionSize, uint256 _entryPrice, uint256 _indexPrice)
        internal
        pure
        returns (int256)
    {
        if (_positionSize == 0 || _entryPrice == 0) {
            return 0;
        }
        int256 entryPrice = _entryPrice.toInt256();
        int256 positionSize = _positionSize.toInt256();
        int256 indexPrice = _indexPrice.toInt256();
        if (_side == Side.LONG) {
            return (indexPrice - entryPrice) * positionSize / entryPrice;
        } else {
            return (entryPrice - indexPrice) * positionSize / entryPrice;
        }
    }

    /// @notice calculate new avg entry price when increase position
    /// @dev for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    ///      for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function calcAveragePrice(
        Side _side,
        uint256 _lastSize,
        uint256 _nextSize,
        uint256 _entryPrice,
        uint256 _nextPrice,
        int256 _realizedPnL
    ) internal pure returns (uint256) {
        if (_nextSize == 0) {
            return 0;
        }
        if (_lastSize == 0) {
            return _nextPrice;
        }
        int256 pnl = calcPnl(_side, _lastSize, _entryPrice, _nextPrice) - _realizedPnL;
        int256 nextSize = _nextSize.toInt256();
        int256 divisor = _side == Side.LONG ? nextSize + pnl : nextSize - pnl;
        return divisor <= 0 ? 0 : _nextSize * _nextPrice / uint256(divisor);
    }
}
