// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.5.17;

import "./UniV3PriceOracle.sol";
import "../../Interfaces/LPInterfaces.sol";
import "../../Interfaces/AlgebraV1Interfaces.sol";
import "../../Utils/UniswapV3Core/TickMath.sol";
import "../../Utils/UniswapV3Core/LiquidityAmounts.sol";

contract AlgebraV1PriceOracle is NFPOracle {

    // Initializes the contract with the aggregate oracle and the Algebra price oracle address.
    constructor(ISourceOracle _aggregateOracle, address _nfpManager) NFPOracle(_aggregateOracle) public {
        nfpManager = _nfpManager;
    }

    /**
      * @notice Checks if the position with the given token ID is supported by the Algebra V1 non-fungible position manager.
      * @param tokenId The ID of the position.
      * @return True if the position is supported, false otherwise.
      */
    function isPositionSupported(uint tokenId) public view returns (bool) {
        (, , address token0, address token1, , , , , , , ) = AlgebraNFPManagerInterface(nfpManager).positions(tokenId);
        address pool = IAlgebraV1Factory(AlgebraNFPManagerInterface(nfpManager).factory()).poolByPair(token0, token1);
        return (supportedPairs[pool] && aggregateOracle.isTokenSupported(token0) && aggregateOracle.isTokenSupported(token1));
    }

    /**
      * @notice Gets the price of the position with the given token ID.
      * @param tokenId The ID of the position.
      * @return The price of the position.
      */
    function getPositionPrice(uint tokenId) public view returns (uint price) {
        require(isPositionSupported(tokenId), "Position not supported");
        // Fetch position data
        (,, address token0, address token1, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1) = AlgebraNFPManagerInterface(nfpManager).positions(tokenId);
        // Fetch price from pool
        (uint160 sqrtRatioX96,,,,,,) = IAlgebraV1Pool(IAlgebraV1Factory(AlgebraNFPManagerInterface(nfpManager).factory()).poolByPair(token0, token1)).globalState();

        price = getPriceByPositionData(PositionData(token0, token1, tickLower, tickUpper, liquidity, tokensOwed0, tokensOwed1), sqrtRatioX96);
    }

    function getPool(uint tokenId) external view returns(address) {
        (,, address token0, address token1,,,,,,,) = AlgebraNFPManagerInterface(nfpManager).positions(tokenId);
        return IAlgebraV1Factory(UniswapNFPManagerInterface(nfpManager).factory()).poolByPair(token0, token1);
    }
}
