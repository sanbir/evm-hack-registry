// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.16;
pragma experimental ABIEncoderV2;

import "../Interfaces/EIP20Interface.sol";
import "../Interfaces/UniswapV3Interfaces.sol";

contract UniswapV3PoolMock is IUniswapV3Pool {
    uint160 priceMock;
    uint128 liquidityMock;
    constructor(uint160 _priceMock, uint128 _liquidityMock) public {
        priceMock = _priceMock;
        liquidityMock = _liquidityMock;
    }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (priceMock, 0, 0, 0, 0, 0, false);
    }

    function liquidity() external view returns (uint128) {
        return liquidityMock;
    }

    function token0() external view returns (address) { revert("not implemented"); }
    function token1() external view returns (address) { revert("not implemented"); }
}

contract UniswapV3FactoryMock is IUniswapV3Factory {
    UniswapV3PoolMock public poolMock;
    UniswapV3PoolMock public emptyPoolMock;

    constructor() public {
        poolMock = new UniswapV3PoolMock(42, 42);
        emptyPoolMock = new UniswapV3PoolMock(0, 0);
    }

    function getPool(address /*tokenA*/, address /*tokenB*/, uint24 fee) external view returns (address) {
        if (fee == 3000) return address(0);
        if (fee == 500) return address(emptyPoolMock);
        else return address(poolMock);
    }
}

contract UniswapV3SwapRouterMock is IUniswapV3SwapRouter {
    IUniswapV3Factory public factoryMock;

    constructor() public {
        factoryMock = new UniswapV3FactoryMock();
    }

    function factory() external returns (address) {
        return address(factoryMock);
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        uint256 extra = 10 * uint256(10) ** EIP20Interface(params.tokenOut).decimals(); // 10 tokens
        require(EIP20Interface(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");
        require(EIP20Interface(params.tokenOut).transfer(params.recipient, params.amountOutMinimum + extra), "transfer failed");
        return params.amountOutMinimum + extra;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) { revert("not implemented"); }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256) {
        require(EIP20Interface(params.tokenIn).transferFrom(msg.sender, address(this), params.amountInMaximum - 100), "transferFrom failed");
        require(EIP20Interface(params.tokenOut).transfer(params.recipient, params.amountOut), "transfer failed");
        return params.amountInMaximum - 100;
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) { revert("not implemented"); }
}
