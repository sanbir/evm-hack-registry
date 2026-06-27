// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "../libraries/OracleLibrary.sol";
import "../interfaces/IP2EFactory.sol";
import "../libraries/P2ELibrary.sol";
import '../libraries/FixedPoint.sol';
import "../interfaces/IP2EPair.sol";

contract Oracle {
    using FixedPoint for *;
    using SafeMath for uint;

    struct Observation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }

    address public immutable factory;
    uint public constant CYCLE = 30 minutes;

    // mapping from pair address to a list of price observations of that pair
    mapping(address => Observation) public pairObservations;

    constructor(address factory_) {
        factory = factory_;
    }


    function update(address tokenA, address tokenB) external {
        if (IP2EFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            return;
        }
        address pair = IP2EFactory(factory).expectPairFor(tokenA, tokenB);

        Observation storage observation = pairObservations[pair];
        uint timeElapsed = block.timestamp - observation.timestamp;
        require(timeElapsed >= CYCLE, 'Oracle: PERIOD_NOT_ELAPSED');
        (uint price0Cumulative, uint price1Cumulative,) = OracleLibrary.currentCumulativePrices(pair);
        observation.timestamp = block.timestamp;
        observation.price0Cumulative = price0Cumulative;
        observation.price1Cumulative = price1Cumulative;
    }


    function computeAmountOut(
        uint priceCumulativeStart, uint priceCumulativeEnd,
        uint timeElapsed, uint amountIn
    ) private pure returns (uint amountOut) {
        // overflow is desired.
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }


    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut) {
        address pair = IP2EFactory(factory).expectPairFor(tokenIn, tokenOut);
        Observation storage observation = pairObservations[pair];
        uint timeElapsed = block.timestamp - observation.timestamp;
        (uint price0Cumulative, uint price1Cumulative,) = OracleLibrary.currentCumulativePrices(pair);
        (address token0,) = P2ELibrary.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return computeAmountOut(observation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(observation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }
}
