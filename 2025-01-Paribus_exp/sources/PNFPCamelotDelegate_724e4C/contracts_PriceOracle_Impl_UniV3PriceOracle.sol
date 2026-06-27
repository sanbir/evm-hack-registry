// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../../Interfaces/UniswapV3Interfaces.sol";
import "../../Utils/UniswapV3Core/TickMath.sol";
import "../../Utils/UniswapV3Core/LiquidityAmounts.sol";
import "../../Interfaces/LPInterfaces.sol";
import "./../PriceOracleInterfaces.sol";
import "openzeppelin2/token/ERC20/ERC20Detailed.sol";
import "openzeppelin2/ownership/Ownable.sol";

/// @dev Non-fungible position oracle for multiple dexes i.e. uniswap and camelot
contract NFPOracle is INFPOracle, Ownable {
    struct PositionData {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokens0Owed;
        uint128 tokens1Owed;
    }

    using SafeMath for uint;

    // main oracle to get prices of pair tokens
    ISourceOracle aggregateOracle;
    
    // derived non fungible position manager contract
    address public nfpManager;

    // mapping of supported pairs
    mapping(address => bool) supportedPairs;

    event PairSupported(address pair);

    /**
      * @notice Constructor to set the aggregate oracle
      * @param _aggregateOracle The address of the aggregate oracle
      */
    constructor(ISourceOracle _aggregateOracle) public {
        aggregateOracle = _aggregateOracle;
    }

    /// @dev converts non-fungible position data into price represented in USD
    function getPriceByPositionData(PositionData memory positionData, uint160 sqrtRatioX96) internal view returns (uint price) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(positionData.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(positionData.tickUpper);

        (uint amount0, uint amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, positionData.liquidity);
        require(amount0 > 0 || amount1 > 0, "liquidity error");
        uint price0 = aggregateOracle.getTokenPrice(positionData.token0, 18);
        uint price1 = aggregateOracle.getTokenPrice(positionData.token1, 18);

        // add uncollected fee and calculate total position value
        uint valueUsd0 = (amount0.add(positionData.tokens0Owed)).mul(price0).div(10 ** uint(ERC20Detailed(positionData.token0).decimals()));
        uint valueUsd1 = (amount1.add(positionData.tokens1Owed)).mul(price1).div(10 ** uint(ERC20Detailed(positionData.token1).decimals()));

        price = valueUsd0.add(valueUsd1);
    }
    
    /**
      * @notice Set the support status of a pair
      * @param pair The address of the pair
    */
    function setSupportedPair(address pair) public onlyOwner {
        supportedPairs[pair] = true;
        emit PairSupported(pair); 
    }

    function getPool(uint tokenId) external view returns(address);
}

contract UniV3PriceOracle is NFPOracle {

    /**
      * @notice Constructor to set the aggregate oracle and UniswapV3 position manager
      * @param _aggregateOracle The address of the aggregate oracle
      * @param _uniV3NFPManager The address of the UniswapV3 non-fungible position manager
      */
    constructor(ISourceOracle _aggregateOracle, address _uniV3NFPManager) NFPOracle(_aggregateOracle) public {
        nfpManager = _uniV3NFPManager;
    }

    function isPositionSupported(uint tokenId) public view returns (bool) {
        (, , address token0, address token1, uint24 fee, , , , , , , ) = UniswapNFPManagerInterface(nfpManager).positions(tokenId);
        address pool = IUniswapV3Factory(UniswapNFPManagerInterface(nfpManager).factory()).getPool(token0, token1, fee);
        // true if pool is supported and both tokens are supported
        return (supportedPairs[pool] && aggregateOracle.isTokenSupported(token0) && aggregateOracle.isTokenSupported(token1));
    }

    // get withdrawable amounts for token0 and token1 for a given position data
    function getPositionPrice(uint tokenId) external view returns (uint price) {
        require(isPositionSupported(tokenId), "Position not supported");
        // Fetch position data
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1) = UniswapNFPManagerInterface(nfpManager).positions(tokenId);
        // Fetch price from pool
        (uint160 sqrtRatioX96,,,,,,) = IUniswapV3Pool(IUniswapV3Factory(UniswapNFPManagerInterface(nfpManager).factory()).getPool(token0, token1, fee)).slot0();
        // convert position data to price
        price = getPriceByPositionData(PositionData(token0, token1, tickLower, tickUpper, liquidity, tokensOwed0, tokensOwed1), sqrtRatioX96);
    }

    function getPool(uint tokenId) external view returns(address) {
        (,, address token0, address token1, uint24 fee,,,,,,,) = UniswapNFPManagerInterface(nfpManager).positions(tokenId);
        return IUniswapV3Factory(UniswapNFPManagerInterface(nfpManager).factory()).getPool(token0, token1, fee);
    }

}
