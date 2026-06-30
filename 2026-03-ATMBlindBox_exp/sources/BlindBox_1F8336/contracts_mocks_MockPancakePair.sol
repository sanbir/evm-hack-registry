// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Minimal PancakeSwap V2 Pair mock with real x*y=k AMM
 */
contract MockPancakePair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32  private blockTimestampLast;
    
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    
    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    
    uint private constant MINIMUM_LIQUIDITY = 1000;
    address public factory;
    
    constructor() { factory = msg.sender; }
    
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
    
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked { timeElapsed = blockTimestamp - blockTimestampLast; }
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            price0CumulativeLast += uint(uint224(_reserve1) * uint224(2**112) / uint224(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(uint224(_reserve0) * uint224(2**112) / uint224(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
    }
    
    function _sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
    
    function mint(address to) external returns (uint liquidity) {
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0 - reserve0;
        uint amount1 = balance1 - reserve1;
        
        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            balanceOf[address(0)] += MINIMUM_LIQUIDITY; // lock
            totalSupply += MINIMUM_LIQUIDITY;
        } else {
            uint liq0 = amount0 * totalSupply / reserve0;
            uint liq1 = amount1 * totalSupply / reserve1;
            liquidity = liq0 < liq1 ? liq0 : liq1;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        balanceOf[to] += liquidity;
        totalSupply += liquidity;
        _update(balance0, balance1, reserve0, reserve1);
    }
    
    function burn(address to) external returns (uint amount0, uint amount1) {
        uint liquidity = balanceOf[address(this)];
        amount0 = liquidity * reserve0 / totalSupply;
        amount1 = liquidity * reserve1 / totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        balanceOf[address(this)] -= liquidity;
        totalSupply -= liquidity;
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
    
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "INSUFFICIENT_LIQUIDITY");
        
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        
        // x*y=k invariant check with 0.3% fee
        uint amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT");
        
        uint balance0Adjusted = balance0 * 10000 - amount0In * 25; // 0.25% fee (PancakeSwap V2)
        uint balance1Adjusted = balance1 * 10000 - amount1In * 25;
        require(balance0Adjusted * balance1Adjusted >= uint(reserve0) * uint(reserve1) * 100000000, "K");
        
        _update(balance0, balance1, reserve0, reserve1);
    }
    
    function sync() external {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
    
    function transfer(address to, uint value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
    
    function approve(address spender, uint value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }
    
    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint).max) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }
}
