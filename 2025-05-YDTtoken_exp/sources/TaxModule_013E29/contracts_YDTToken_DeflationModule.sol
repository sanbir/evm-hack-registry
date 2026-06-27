// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";
import "./YDTMainContract.sol";

contract DeflationModule {
    using SafeMath for uint256;

    // 通缩配置参数
    uint256 public constant DAILY_DEFLATION_RATE = 3;  
    uint256 public constant DEFLATION_BURN = 1;        
    uint256 public constant DEFLATION_C = 1;           
    uint256 public constant DEFLATION_B = 1;           

    YDTMainContract public ydtToken;
 
    uint256 public lastDeflationTime;
    uint256 public constant DAY_IN_SECONDS = 86400;

    constructor(address _ydtToken) {
        ydtToken = YDTMainContract(_ydtToken);
        lastDeflationTime = block.timestamp;
    }

    // 通过主合约获取上下文信息
    function getAddressB() private view returns (address) {
        return ydtToken.getAddressB();
    }

    function getAddressC() private view returns (address) {
        return ydtToken.getAddressC();
    }

    function getPancakePair() private view returns (address) {
        return ydtToken.getPancakePair();
    }

    // 通缩机制 - 每天自动执行,可以由任何人触发，但每天只能触发一次
    function applyDeflation() external {
        require(block.timestamp >= lastDeflationTime + DAY_IN_SECONDS, "Deflation can only be applied once per day");
        address poolAddress = getPancakePair();
        console.log("Deflation pool address:", poolAddress);
        
        // 获取池子中的YDT余额
        uint256 poolBalance = ydtToken.balanceOf(poolAddress);
        console.log("Pool balance:", poolBalance);
        require(poolBalance > 0, "No tokens in pool");
        
        // 计算通缩总量 (3% of pool balance)
        uint256 deflationAmount = poolBalance.mul(DAILY_DEFLATION_RATE).div(100);
        console.log("Total deflation amount (3%):", deflationAmount);
        
        // 分配通缩
        uint256 burnAmount = deflationAmount.mul(DEFLATION_BURN).div(DAILY_DEFLATION_RATE);
        uint256 toBAmount = deflationAmount.mul(DEFLATION_B).div(DAILY_DEFLATION_RATE);
        uint256 toCAmount = deflationAmount.mul(DEFLATION_C).div(DAILY_DEFLATION_RATE);
        
        console.log("Burn amount (1%):", burnAmount);
        console.log("Address B allocation (1%):", toBAmount);
        console.log("LP holders allocation (1%):", toCAmount);
        
        // 执行销毁
        ydtToken.burnTokens(poolAddress, burnAmount);
        
        // 分配给B地址
        ydtToken.proxyTransfer(poolAddress, getAddressB(), toBAmount, address(this));

        ydtToken.getLPTrackingModule().processLPOperations(100);
        
        try ydtToken.getLPTrackingModule().getLPHolders() returns (address[] memory holders) {
            console.log("Got LP holders list, count:", holders.length);
            
            // 分配给LP持有者
            if (holders.length > 0) {
                for (uint i = 0; i < holders.length; i++) {
                    address holder = holders[i];
                    try ydtToken.getLPTrackingModule().calculateUserReward(holder, toCAmount) returns (uint256 reward) {
                        if (reward > 0) {
                            ydtToken.proxyTransfer(poolAddress, holder, reward, address(this));
                        }
                    } catch {
                        console.log("Failed to calculate reward for:", holder);
                    }
                }
                console.log("LP holders rewards distribution completed");
            } else {
                // 如果没有LP持有者，将toCAmount直接发送给C地址
                console.log("No LP holders, sending directly to address C");
                ydtToken.proxyTransfer(poolAddress, getAddressC(), toCAmount, address(this));
            }
        } catch {
            console.log("Failed to get LP holders list, sending to address C");
            ydtToken.proxyTransfer(poolAddress, getAddressC(), toCAmount, address(this));
        }
        
        // 更新最后通缩时间
        lastDeflationTime = block.timestamp;
        console.log("Deflation completed");
    }

    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "DeflationModule: Only main contract can call");
        require(to != address(0), "DeflationModule: Invalid recipient address");
        require(amount > 0, "DeflationModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "DeflationModule: Insufficient balance");
        
        token.transfer(to, amount);
    }

  
}