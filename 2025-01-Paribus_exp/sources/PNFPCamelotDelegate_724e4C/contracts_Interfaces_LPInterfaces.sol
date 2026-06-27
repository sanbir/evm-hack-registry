// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

contract LPTokenInterface {
    address public token0;
    address public token1;

    function getReserves() external view returns (uint112, uint112, uint32);

    function totalSupply() external view returns (uint);

    function factory() external view returns (address);

    function kLast() external view returns (uint);
}

contract NFPManagerInterface {
    address public token0;
    address public token1;

    function factory() external view returns (address);
}

contract UniswapNFPManagerInterface is NFPManagerInterface {
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint feeGrowthInside0LastX128;
        uint feeGrowthInside1LastX128;
        uint128 tokens0Owed;
        uint128 tokens1Owed;
    }

    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
    
    // function positions1(uint256 tokenId) external view returns (
    //     Position memory position
    // );
}

contract AlgebraNFPManagerInterface is NFPManagerInterface {
    // algebra v1.9 position struct is slightly different from UniV3
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint feeGrowthInside0LastX128;
        uint feeGrowthInside1LastX128;
        uint128 tokens0Owed;
        uint128 tokens1Owed;
    }

    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );

    // function positions1(uint256 tokenId) external view returns (
    //     Position memory position
    // );
}