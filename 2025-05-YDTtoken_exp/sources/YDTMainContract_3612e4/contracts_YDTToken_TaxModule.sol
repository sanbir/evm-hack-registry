// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./YDTMainContract.sol";
import "hardhat/console.sol";
contract TaxModule {
    using SafeMath for uint256;
    YDTMainContract public ydtToken;
    constructor(address _ydtToken) {
        ydtToken = YDTMainContract(_ydtToken);
    }
    modifier onlyAuthorizedCaller() {
        require(msg.sender == address(ydtToken)  ,"Unauthorized caller");
        _;
    }
    function handleTransferTax(address sender,address recipient,uint256 amount) external onlyAuthorizedCaller  returns (uint256)    {
        address pancakePair = ydtToken.getPancakePair();
        
        address liquidityModule = address(ydtToken.getLiquidityModule());
        address liquidityRemovalModule = address(ydtToken.getLiquidityRemovalModule());
        address deflationModule = address(ydtToken.getDeflationModule());
        // 排除流动性模块的交易
        if (sender == liquidityModule || recipient == liquidityModule) {
        
            return amount; // 不收税，直接返回原始金额
        }
        if (sender == liquidityRemovalModule || recipient == liquidityRemovalModule) {
 
            return amount; // 不收税，直接返回原始金额
        }
        if (sender == deflationModule || recipient == deflationModule) {
     
            return amount; // 不收税，直接返回原始金额
        }
        // 检查是否是卖出交易
        if (recipient == pancakePair) {       
            // 收取10%的卖出税给A地址
            uint256 tax = amount.mul(100).div(1000);
            uint256 amountAfterTax = amount.sub(tax);          
            uint256 senderBalance = ydtToken.balanceOf(sender);
            // 检查是否有足够的余额
            if (amount > 0 && senderBalance >= amount) {       
                console.log("proxyTransfer.start");
                // 将税部分转给A地址
                ydtToken.proxyTransfer(sender, ydtToken.getAddressA(), tax, address(this));
                console.log("proxyTransfer.end");
            }

            return amountAfterTax;
        }
        // 检查是否是购买交易 (非白名单不能购买)
        else if (sender == pancakePair) {
            if(ydtToken.isWhitelisted(recipient)){
                return amount;
            }else{
                revert("001");
            }
        }
        return amount;
    }
 
    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "TaxModule: Only main contract can call");
        require(to != address(0), "TaxModule: Invalid recipient address");
        require(amount > 0, "TaxModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "TaxModule: Insufficient balance");
        
        token.transfer(to, amount);
    }
 
}
