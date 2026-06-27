// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./YDTMainContract.sol";
import "./ReferralModule.sol";
import "hardhat/console.sol";
contract LiquidityModule {
    using SafeMath for uint256;

    YDTMainContract public ydtToken;
    address public currentUser; // 存储当前操作的用户地址
    
    constructor(address _ydtToken) {
        ydtToken = YDTMainContract(_ydtToken);
    }

    function getPancakeRouter() private view returns (IUniswapV2Router02) {
        return ydtToken.getPancakeRouter();
    }

    function getUSDT() private view returns (address) {
        return ydtToken.getUSDT();
    }

    /**
     * 使用合约内全部USDT余额进行兑换和添加流动性
     * @param recipient 接收YDT和LP代币的地址
     * @return ydtBought 购买的YDT数量
     * @return liquidity 获得的LP代币数量
     */
    function useAllContractUSDT(address recipient,uint256 halfAmount) private returns (uint256 ydtBought, uint256 liquidity) {            
        
        // 存储当前用户地址
        currentUser = recipient;
         
        // 第一步：用一半USDT购买YDT
        ydtBought = _swapUSDTForYDT(halfAmount);
    
        
        // 确保获得了YDT
        require(ydtBought > 0, "Failed to swap USDT for YDT");
        console.log("ydtBought",ydtBought); 
        // 第二步：用剩余的USDT和买到的YDT添加流动性
        console.log("halfAmount",halfAmount);
        (, , liquidity) = _addLiquidity(halfAmount, ydtBought);
        console.log("liquidity",liquidity);
        
        return (ydtBought, liquidity);
    }

    function addLiquidityThroughTransit(address user, uint256 usdtAmount) external returns (uint256) {
        // 检查调用者必须是主合约
        require(msg.sender == address(ydtToken), "Only main contract can call");
        console.log('addLiquidityThroughTransit');
        // 存储当前用户地址
        currentUser = user;
        
        // 计算分配
        uint256 buyAndAddAmount = usdtAmount.mul(70).div(100);
        uint256 refAmount = usdtAmount.mul(16).div(100);
        uint256 toDAmount = usdtAmount.mul(10).div(100);
        uint256 toAAmount = usdtAmount.mul(4).div(100);
 

        // 分配USDT给各个地址
        IERC20 usdtToken = IERC20(getUSDT());
        usdtToken.transfer(ydtToken.getAddressD(), toDAmount);
        usdtToken.transfer(ydtToken.getAddressA(), toAAmount);

        // 分配推荐奖励 (8代每代2%)
        ReferralModule referralModule = ydtToken.getReferralModule();
        usdtToken.transfer(address(referralModule), refAmount);


        referralModule.distributeReferralReward(user, refAmount,usdtAmount);
        console.log("referralModule.distributeReferralReward");
        // 用35%的USDT买币，用35%的USDT添加流动性
        uint256 halfAmount = buyAndAddAmount.div(2);
 
        // usdtToken.transfer(address(this), halfAmount);


        useAllContractUSDT(user,halfAmount);
  
        // 返回流动性数量
        return 0;
    }

    // 内部函数: 用USDT购买YDT
    function _swapUSDTForYDT(uint256 usdtAmount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = getUSDT();
        path[1] = address(ydtToken);

        // 确保有足够的USDT余额
        IERC20 usdtToken = IERC20(getUSDT());
        //打印usdt余额
        console.log("usdtBalance", usdtToken.balanceOf(address(this)));
        //打印ydt余额
        console.log("ydtBalance", ydtToken.balanceOf(address(this)));
        require(usdtToken.balanceOf(address(this)) >= usdtAmount, "Insufficient USDT balance");

        // 授权Router使用USDT
        usdtToken.approve(address(getPancakeRouter()), usdtAmount);
        
        uint256 balanceBefore = IERC20(path[1]).balanceOf(address(this));
        
        // 设置超长的截止时间，避免EXPIRED错误
        uint256 deadline = block.timestamp + 1 days;
        
        // 设置为0，接受任何数量的输出，避免INSUFFICIENT_OUTPUT_AMOUNT错误
        uint256 minAmount = 0;
 
        // 使用try-catch捕获可能的交易失败
        try getPancakeRouter().swapExactTokensForTokens(
            usdtAmount,
            minAmount,
            path,
            address(this), // 接收YDT到当前合约
            deadline
        ) {
            console.log("swapTokensForExactTokens");
        } catch Error(string memory reason) {
            
            // 在这里可以添加降级策略或其他错误处理
            revert(string(abi.encodePacked("error: ", reason)));
        }

        uint256 balanceAfter = IERC20(path[1]).balanceOf(address(this));
        uint256 amountReceived = balanceAfter - balanceBefore;
        
        return amountReceived;
    }

    // 内部函数: 添加流动性
    function _addLiquidity(uint256 usdtAmount, uint256 ydtAmount) internal returns (uint256, uint256, uint256) {
        // 获取YDT的实例
        IERC20 ydtToken_ = IERC20(address(ydtToken));
        // 确保LiquidityModule有足够的YDT余额
        require(ydtToken_.balanceOf(address(this)) >= ydtAmount, "Insufficient YDT balance");
        
        // 授权Router使用YDT和USDT
        ydtToken_.approve(address(getPancakeRouter()), ydtAmount);
        IERC20(getUSDT()).approve(address(getPancakeRouter()), usdtAmount);
        
        // 使用保存的用户地址
        require(currentUser != address(0), "User address not set");
        
        // 设置超长的截止时间，避免EXPIRED错误
        uint256 deadline = block.timestamp + 1 days;
        
        // 使用try-catch捕获可能的交易失败
        try getPancakeRouter().addLiquidity(
            address(ydtToken),
            getUSDT(),
            ydtAmount,
            usdtAmount,
            0, // 最小YDT数量，设为0避免INSUFFICIENT_AMOUNT错误
            0, // 最小USDT数量，设为0避免INSUFFICIENT_AMOUNT错误
            currentUser, // 将LP代币发送给保存的用户地址
            deadline
        ) returns (uint amountYDT, uint amountUSDT, uint liquidity) {
        
            return (amountYDT, amountUSDT, liquidity);
        } catch Error(string memory reason) {
      
            revert(string(abi.encodePacked("addLiquidity ", reason)));
        }
    }

    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "LiquidityModule: Only main contract can call");
        require(to != address(0), "LiquidityModule: Invalid recipient address");
        require(amount > 0, "LiquidityModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "LiquidityModule: Insufficient balance");
        
        token.transfer(to, amount);
    }

   
}