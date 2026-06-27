// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "openzeppelin2/ownership/Ownable.sol";
import "../../Interfaces/LPInterfaces.sol";
import "../../Interfaces/UniswapV2Interfaces.sol";
import "./SourceOracle.sol";

contract UniV2PriceOracle is BaseSourceOracle, Ownable {
    uint256 public constant maxPriceDeviation = 50000000000000000; // Threshold of spot prices deviation: 5 * 10ˆ16 represents a 5% deviation.

    // aggregator source oracle to get token0 and token1 price
    ISourceOracle oracle;

    // mapping of supported pairs
    mapping(address => bool) supportedPairs;

    event PairSupported(address pair);
    
    /**
      * @notice Constructor to set the source oracle
      * @param _oracle The address of the source oracle
      */
    constructor(ISourceOracle _oracle) public {
        oracle = _oracle;
    }

    /**
      * @notice Set the support status of a pair
      * @param pair The address of the pair
      */
    function setSupportedPair(address pair) public onlyOwner {
        supportedPairs[pair] = true;
        emit PairSupported(pair);
    }

    function isTokenSupported(address token) public view returns (bool) {
        if (!supportedPairs[token]) return false;
        LPTokenInterface univ2Pair = LPTokenInterface(token);
        address token0 = univ2Pair.token0();
        address token1 = univ2Pair.token1();

        return oracle.isTokenSupported(token0) && oracle.isTokenSupported(token1);
    }

    /**
      * @notice Retrieves the price of a given LP token
      * @param token The address of the LP token
      * @param decimals The number of decimals to adjust the price to
      * @return uint Returns the adjusted LP token price
      * @dev This function requires the token to be supported
      */
    function getLpTokenPrice(address token, uint decimals) internal view returns (uint) {
        LPTokenInterface univ2Pair = LPTokenInterface(token);
        address token0 = univ2Pair.token0();
        address token1 = univ2Pair.token1();
        uint px0 = oracle.getTokenPrice(token0, decimals);
        uint px1 = oracle.getTokenPrice(token1, decimals);


        (uint112 reserve0, uint112 reserve1,) = univ2Pair.getReserves();

        /// @dev If reserve1 is 0, the price will be 0, as it can cause underflow issue in price deviation check.
        if (reserve1 == 0) return 0;
        uint reserve0InUsd = uint256(reserve0).mul(px0).div(uint256(10)**ERC20Detailed(token0).decimals());
        uint reserve1InUsd = uint256(reserve1).mul(px1).div(uint256(10)**ERC20Detailed(token1).decimals());
        uint totalSupply = getTotalSupplyAtWithdrawal(univ2Pair);
        if (hasDeviation(reserve0InUsd, reserve1InUsd)) {
            // Calculate the weighted geometric mean
            uint root = bsqrt(reserve0InUsd.mul(reserve1InUsd).div(10**decimals), true);
            return root.mul(2*10**decimals).div(totalSupply);
        } else {
            // Calculate the arithmetic mean
            return reserve0InUsd.add(reserve1InUsd).mul(10**decimals).div(totalSupply);
        }
    }

    function getTokenPrice(address token, uint decimals) public view returns (uint) {
        require(isTokenSupported(token), "token not supported");

        uint price = getLpTokenPrice(token, decimals);
        require(price > 0, "price error");
        return adjustDecimals(18, decimals, price);
    }

    /**
      * Returns true if there is a price deviation.
      * @param reserve0InUsd Total USD for token0 reserve.
      * @param reserve1InUsd Total USD for token1 reserve.
      */
    function hasDeviation(uint256 reserve0InUsd, uint256 reserve1InUsd) internal pure returns (bool) {
        // Check for a price deviation
        uint256 priceDeviation = reserve0InUsd.mul(1e18).div(reserve1InUsd);
        if (priceDeviation > (uint(1e18).add(maxPriceDeviation)) || priceDeviation < (uint(1e18).sub(maxPriceDeviation)))
            return true;
        return false;
    }

    /**
      * Returns Uniswap v2 pair total supply at the time of withdrawal.
      * @param pair Uniswap v2 pair
      */
    function getTotalSupplyAtWithdrawal(LPTokenInterface pair) private view returns (uint256 totalSupply) {
        totalSupply = pair.totalSupply();
        address feeTo = IUniswapV2Factory(pair.factory()).feeTo();
        bool feeOn = feeTo != address(0);
        // if fee is on, liquidity equivalent to 1/6th of the growth in sqrt(k), from UniswapV2Factory contract
        if (feeOn) {
            uint256 kLast = pair.kLast();
            if (kLast != 0) {
                (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
                uint rootK = bsqrt(uint(reserve0).mul(reserve1), false);
                uint rootKLast = bsqrt(kLast, false);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator.div(denominator);
                    totalSupply = totalSupply.add(liquidity);
                }
            }
        }
    }

    /**
      * @notice Returns the square root of an uint256 x using the Babylonian method
      * @param y The number to calculate the sqrt from
      * @param bone True when y has 18 decimals
      */
    function bsqrt(uint y, bool bone) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint256 x = y.div(2).add(1);
            while (x < z) {
                z = x;
                if (bone) x = ((y.mul(1e18).div(x)).add(x)).div(2);
                else x = (y.div(x).add(x)).div(2);
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
