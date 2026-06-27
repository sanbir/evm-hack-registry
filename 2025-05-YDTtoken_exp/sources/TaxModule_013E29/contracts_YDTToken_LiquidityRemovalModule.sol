// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";
import "./YDTMainContract.sol";
interface IPancakeRouter {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

 

/**
 * @title LiquidityRemovalModule
 * @dev 用于接收用户LP代币并自动执行移除流动性操作的中转合约
 */
contract LiquidityRemovalModule is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    YDTMainContract public ydtToken;
    address private _ydtAddress;
    
    // 事件声明
    event LiquidityRemoved(address indexed user, uint256 lpAmount, uint256 ydtReceived, uint256 usdtReceived);
    event EmergencyWithdraw(address token, address to, uint256 amount);
    
    // 构造函数
    constructor(address _ydtTokenAddress) {
        require(_ydtTokenAddress != address(0), "YDT: Zero address");
        ydtToken = YDTMainContract(_ydtTokenAddress);       
    }
    
    function removeLiquidityForUser(address recipient, uint256 lpAmount) external {
        require(lpAmount > 0, "Amount must be greater than 0");
        
        // 优化变量使用，减少栈深度
        _doRemoveLiquidity(recipient, lpAmount, 0, 0);
    }
    
    /**
     * @dev 内部函数，执行实际的移除流动性操作
     */
    function _doRemoveLiquidity(
        address recipient,
        uint256 lpAmount,
        uint256 minYDTAmount,
        uint256 minUSDTAmount
    ) private {
        // 获取必要的地址
        address pancakePair = address(ydtToken.pancakePair());
        address routerAddress = address(ydtToken.getPancakeRouter());
        
        // 授权Router使用LP代币
        
        IERC20(pancakePair).safeApprove(routerAddress, lpAmount);
        
        // 执行移除流动性操作
        (uint256 ydtAmount, uint256 usdtAmount) = IPancakeRouter(routerAddress).removeLiquidity(
            address(ydtToken),
            ydtToken.getUSDT(),
            lpAmount,
            minYDTAmount,
            minUSDTAmount,
            address(this),
            block.timestamp + 1 days
        );
        
        IERC20(ydtToken.getUSDT()).safeTransfer(recipient, usdtAmount);
        IERC20(address(ydtToken)).safeTransfer(recipient, ydtAmount);
        // 触发事件
        emit LiquidityRemoved(recipient, lpAmount, ydtAmount, usdtAmount);
    }
    
    /**
     * @dev 紧急情况下允许管理员提取合约中的代币
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function emergencyWithdraw(address tokenAddress, address to, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).safeTransfer(to, amount);
        emit EmergencyWithdraw(tokenAddress, to, amount);
    }
    
    /**
     * @dev 计算移除流动性后能获得的代币数量
     * @param lpAmount LP代币数量
     * @return ydtAmount 预计获得的YDT数量
     * @return usdtAmount 预计获得的USDT数量
     */
    function calculateRemoveLiquidity(uint256 lpAmount) external view returns (uint256 ydtAmount, uint256 usdtAmount) {
        // 获取必要的合约地址
        address pancakePair = ydtToken.pancakePair();
        address usdtAddress = ydtToken.getUSDT();
        
        // 获取LP代币的总供应量
        uint256 totalSupply = IERC20(pancakePair).totalSupply();
        if (totalSupply == 0 || lpAmount == 0) {
            return (0, 0);
        }
        
        // 获取池子中的代币余额
        uint256 ydtBalance = IERC20(_ydtAddress).balanceOf(pancakePair);
        uint256 usdtBalance = IERC20(usdtAddress).balanceOf(pancakePair);
        
        // 计算移除后能获得的代币数量
        ydtAmount = lpAmount.mul(ydtBalance).div(totalSupply);
        usdtAmount = lpAmount.mul(usdtBalance).div(totalSupply);
        
        return (ydtAmount, usdtAmount);
    }
    
    /**
     * @dev 升级合约主地址，仅限所有者调用
     * @param newYDTAddress 新的YDT合约地址
     */
    function upgradeYDTAddress(address newYDTAddress) external onlyOwner {
        require(newYDTAddress != address(0), "YDT: Zero address");
        ydtToken = YDTMainContract(newYDTAddress);
        _ydtAddress = newYDTAddress;
    }
    
    /**
     * @dev 检查合约是否有足够的权限执行操作
     */
    function checkContractPermission() external view returns (bool) {
        // 获取必要的合约地址
        address pancakePair = address(ydtToken.pancakePair());
        address routerAddress = address(ydtToken.getPancakeRouter());
        
        // 检查地址是否有效
        if (pancakePair == address(0) || routerAddress == address(0)) {
            return false;
        }
        
        return true;
    }

    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "LiquidityRemovalModule: Only main contract can call");
        require(to != address(0), "LiquidityRemovalModule: Invalid recipient address");
        require(amount > 0, "LiquidityRemovalModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "LiquidityRemovalModule: Insufficient balance");
        
        token.safeTransfer(to, amount);
    }

 
} 