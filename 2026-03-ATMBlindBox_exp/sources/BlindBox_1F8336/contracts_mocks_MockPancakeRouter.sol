// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPancakePair.sol";
import "./MockPancakeFactory.sol";

contract MockPancakeRouter {
    address public immutable factory;
    address public WETH;
    
    constructor(address _factory) { 
        factory = _factory;
        WETH = address(this); // use self as WETH placeholder
    }
    
    function _sortTokens(address tA, address tB) internal pure returns (address t0, address t1) {
        (t0, t1) = tA < tB ? (tA, tB) : (tB, tA);
    }
    
    function _getPair(address tA, address tB) internal view returns (address) {
        return MockPancakeFactory(factory).getPair(tA, tB);
    }
    
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure returns (uint amountOut) {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "INVALID");
        uint amountInWithFee = amountIn * 9975; // 0.25% fee (PancakeSwap V2)
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        require(path.length >= 2, "PATH");
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            address pair = _getPair(path[i], path[i+1]);
            (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
            (address t0,) = _sortTokens(path[i], path[i+1]);
            (uint rIn, uint rOut) = path[i] == t0 ? (uint(r0), uint(r1)) : (uint(r1), uint(r0));
            amounts[i+1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }
    
    function addLiquidity(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint, uint, address to, uint
    ) external returns (uint amountA, uint amountB, uint liquidity) {
        address pair = _getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = MockPancakeFactory(factory).createPair(tokenA, tokenB);
        }
        amountA = amountADesired;
        amountB = amountBDesired;
        IERC20(tokenA).transferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).transferFrom(msg.sender, pair, amountB);
        liquidity = MockPancakePair(pair).mint(to);
    }
    
    function swapExactTokensForTokens(
        uint amountIn, uint amountOutMin,
        address[] calldata path, address to, uint
    ) external returns (uint[] memory amounts) {
        amounts = this.getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "SLIPPAGE");
        address pair = _getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amounts[0]);
        _swap(amounts, path, to);
    }
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin,
        address[] calldata path, address to, uint
    ) external {
        address pair = _getPair(path[0], path[1]);
        // Transfer input tokens to pair (may trigger ATM hooks that call pair.swap)
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);

        // PCS V2 approach: read reserves AFTER transfer, amountIn = balance - reserve
        // This correctly handles hooks that update reserves during transfer
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        (address t0,) = _sortTokens(path[0], path[1]);
        (uint rIn, uint rOut) = path[0] == t0 ? (uint(r0), uint(r1)) : (uint(r1), uint(r0));
        uint actualIn = IERC20(path[0]).balanceOf(pair) - rIn;
        uint amountOut = getAmountOut(actualIn, rIn, rOut);
        require(amountOut >= amountOutMin, "SLIPPAGE");
        
        (uint a0Out, uint a1Out) = path[0] == t0 ? (uint(0), amountOut) : (amountOut, uint(0));
        IPancakePair(pair).swap(a0Out, a1Out, to, "");
    }
    
    function removeLiquidity(
        address tokenA, address tokenB,
        uint liquidity, uint, uint,
        address to, uint
    ) external returns (uint amountA, uint amountB) {
        address pair = _getPair(tokenA, tokenB);
        // transfer LP tokens to pair
        MockPancakePair(pair).transferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = MockPancakePair(pair).burn(to);
        (address t0,) = _sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == t0 ? (amount0, amount1) : (amount1, amount0);
    }
    
    function _swap(uint[] memory amounts, address[] calldata path, address to) internal {
        for (uint i; i < path.length - 1; i++) {
            address pair = _getPair(path[i], path[i+1]);
            (address t0,) = _sortTokens(path[i], path[i+1]);
            (uint a0Out, uint a1Out) = path[i] == t0 
                ? (uint(0), amounts[i+1]) 
                : (amounts[i+1], uint(0));
            address recipient = i < path.length - 2 ? _getPair(path[i+1], path[i+2]) : to;
            IPancakePair(pair).swap(a0Out, a1Out, recipient, "");
        }
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin,
        address[] calldata path, address to, uint
    ) external {
        // For testnet: just do a regular token swap (no actual ETH conversion)
        address pair = _getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        
        // PCS V2 approach: balance - reserve after transfer
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        (address t0,) = _sortTokens(path[0], path[1]);
        (uint rIn, uint rOut) = path[0] == t0 ? (uint(r0), uint(r1)) : (uint(r1), uint(r0));
        uint actualIn = IERC20(path[0]).balanceOf(pair) - rIn;
        uint amountOut = getAmountOut(actualIn, rIn, rOut);
        require(amountOut >= amountOutMin, "SLIPPAGE");
        
        (uint a0Out, uint a1Out) = path[0] == t0 ? (uint(0), amountOut) : (amountOut, uint(0));
        IPancakePair(pair).swap(a0Out, a1Out, to, "");
    }
}
