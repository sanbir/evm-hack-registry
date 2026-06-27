// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "hardhat/console.sol";
import "./YDTMainContract.sol";

contract LPHolderTrackingModule {
    using SafeMath for uint256;

    YDTMainContract public ydtToken;
    
    // LP操作记录结构
    struct LPOperation {
        address user;          // 用户地址
        bool isAdd;            // true: 添加流动性, false: 移除流动性
        uint256 lpAmount;      // LP代币数量
        uint256 timestamp;     // 操作时间戳
        bool processed;        // 是否已处理
    }
    
    // LP操作记录队列
    LPOperation[] public lpOperations;
    uint256 public nextOperationIndex; // 下一个要处理的操作索引
    
    // 排除的地址列表
    mapping(address => bool) public excludedFromTracking;
    
    // 用户LP份额映射
    mapping(address => uint256) public userLPShares;
    
    // 总LP份额(排除M地址后)
    uint256 public totalTrackedLPShares;
    
    // LP持有者名单
    address[] private lpHoldersList;
    mapping(address => bool) private isInHoldersList;
    
    // 事件
    event LPOperationRecorded(address indexed user, bool isAdd, uint256 lpAmount, uint256 timestamp);
    event LPSharesUpdated(address indexed user, uint256 newShares);
    event ExcludedStatusChanged(address indexed user, bool isExcluded);
    event RewardsDistributed(uint256 totalAmount, uint256 timestamp);
    event LPOperationsProcessed(uint256 fromIndex, uint256 toIndex);
    
    constructor(address _ydtToken, address _mAddress) {
        ydtToken = YDTMainContract(_ydtToken);        
        // 默认排除M地址
        excludedFromTracking[_mAddress] = true;     
    }
    
    // 更新排除地址
    function updateExcludedAddress(address oldAddress, address newAddress) external {
        require(
            msg.sender == address(ydtToken) || 
            msg.sender == ydtToken.owner(),
            "Only YDTToken or owner can update"
        );
        
        // 如果旧地址被排除，则新地址也被排除
        if (excludedFromTracking[oldAddress]) {
            excludedFromTracking[newAddress] = true;
            excludedFromTracking[oldAddress] = false;
            
            emit ExcludedStatusChanged(oldAddress, false);
            emit ExcludedStatusChanged(newAddress, true);
        }
    }
    
    // 获取LP Token
    function getLpToken() public view returns (IERC20) {
        address lpTokenAddress = ydtToken.getPancakePair();
        return IERC20(lpTokenAddress);
    }
    
    // 1. 记录LP操作 - 可由主合约调用
    function recordLPOperation(address user, bool isAdd, uint256 lpAmount) public {
        require(
            msg.sender == address(ydtToken) ||
            msg.sender == ydtToken.owner() ||
            msg.sender == address(ydtToken.getDeflationModule()) ||
            msg.sender == address(this),
            "Only authorized modules can call"
        );
        
        if (excludedFromTracking[user]) {
            return; // 排除的地址不记录操作
        }
        
        // 创建新的LP操作记录
        lpOperations.push(LPOperation({
            user: user,
            isAdd: isAdd,
            lpAmount: lpAmount,
            timestamp: block.timestamp,
            processed: false
        }));
        
        emit LPOperationRecorded(user, isAdd, lpAmount, block.timestamp);
    }
    
    // 2. 处理LP操作队列 - 更新LP份额
    function processLPOperations(uint256 batchSize) external {
        uint256 endIndex = nextOperationIndex + batchSize;
        if (endIndex > lpOperations.length) {
            endIndex = lpOperations.length;
        }
        
        for (uint256 i = nextOperationIndex; i < endIndex; i++) {
            LPOperation storage operation = lpOperations[i];
            if (!operation.processed && !excludedFromTracking[operation.user]) {
                // 根据实际LP代币余额更新
                uint256 currentLPBalance = getLpToken().balanceOf(operation.user);
                uint256 oldShares = userLPShares[operation.user];
                
                console.log("Processing LP operation for user:");
                console.log(operation.user);
                console.log("Current LP balance:", currentLPBalance);
                console.log("Old shares:", oldShares);
                
                if (oldShares != currentLPBalance) {
                    userLPShares[operation.user] = currentLPBalance;
                    totalTrackedLPShares = totalTrackedLPShares.sub(oldShares).add(currentLPBalance);
                    
                    // 更新持有者列表
                    if (currentLPBalance > 0 && oldShares == 0) {
                        _addToHoldersList(operation.user);
                    } else if (currentLPBalance == 0 && oldShares > 0) {
                        _removeFromHoldersList(operation.user);
                    }
                    
                    emit LPSharesUpdated(operation.user, currentLPBalance);
                }
                
                operation.processed = true;
            }
        }
        
        nextOperationIndex = endIndex;
        emit LPOperationsProcessed(nextOperationIndex, endIndex);
    }
    
    // 3. 获取未处理的操作数量
    function getPendingOperationsCount() external view returns (uint256) {
        return lpOperations.length - nextOperationIndex;
    }
    
    // 获取LP操作队列的总长度
    function getTotalLPOperationsCount() external view returns (uint256) {
        return lpOperations.length;
    }
    
    // 获取指定范围内的LP操作记录
    function getLPOperationsByRange(uint256 startIndex, uint256 endIndex) 
        external 
        view 
        returns (
            address[] memory users,
            bool[] memory isAdds,
            uint256[] memory amounts,
            uint256[] memory timestamps,
            bool[] memory processedFlags
        ) 
    {
        require(startIndex < endIndex, "Invalid range");
        require(endIndex <= lpOperations.length, "End index out of bounds");
        
        uint256 count = endIndex - startIndex;
        users = new address[](count);
        isAdds = new bool[](count);
        amounts = new uint256[](count);
        timestamps = new uint256[](count);
        processedFlags = new bool[](count);
        
        for (uint256 i = 0; i < count; i++) {
            LPOperation storage op = lpOperations[startIndex + i];
            users[i] = op.user;
            isAdds[i] = op.isAdd;
            amounts[i] = op.lpAmount;
            timestamps[i] = op.timestamp;
            processedFlags[i] = op.processed;
        }
        
        return (users, isAdds, amounts, timestamps, processedFlags);
    }
    
    // 获取指定用户的所有LP操作记录
    function getUserLPOperations(address user) 
        external 
        view 
        returns (
            uint256[] memory indices,
            bool[] memory isAdds,
            uint256[] memory amounts,
            uint256[] memory timestamps,
            bool[] memory processedFlags
        ) 
    {
        // 首先计算用户操作的数量
        uint256 userOpCount = 0;
        for (uint256 i = 0; i < lpOperations.length; i++) {
            if (lpOperations[i].user == user) {
                userOpCount++;
            }
        }
        
        // 如果没有操作记录，返回空数组
        if (userOpCount == 0) {
            return (
                new uint256[](0),
                new bool[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0)
            );
        }
        
        // 创建返回数组
        indices = new uint256[](userOpCount);
        isAdds = new bool[](userOpCount);
        amounts = new uint256[](userOpCount);
        timestamps = new uint256[](userOpCount);
        processedFlags = new bool[](userOpCount);
        
        // 填充数组
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < lpOperations.length; i++) {
            if (lpOperations[i].user == user) {
                indices[currentIndex] = i;
                isAdds[currentIndex] = lpOperations[i].isAdd;
                amounts[currentIndex] = lpOperations[i].lpAmount;
                timestamps[currentIndex] = lpOperations[i].timestamp;
                processedFlags[currentIndex] = lpOperations[i].processed;
                currentIndex++;
            }
        }
        
        return (indices, isAdds, amounts, timestamps, processedFlags);
    }
    
    // 4. 手动触发特定用户的LP份额更新
    function updateUserLPShares(address user) public {
        if (excludedFromTracking[user]) {
            console.log("User is excluded, not updating LP share:");
            console.log(user);
            return;
        }
        
        uint256 oldShares = userLPShares[user];
        uint256 newShares = getLpToken().balanceOf(user);
        console.log("Update user LP shares - Address:");
        console.log(user);
        console.log("Old shares:", oldShares);
        console.log("New shares:", newShares);

        if (oldShares != newShares) {
            userLPShares[user] = newShares;
            totalTrackedLPShares = totalTrackedLPShares.sub(oldShares).add(newShares);

            // 更新持有者列表
            if (newShares > 0 && oldShares == 0) {
                _addToHoldersList(user);
                console.log("Added to LP holders list:");
                console.log(user);
            } else if (newShares == 0 && oldShares > 0) {
                _removeFromHoldersList(user);
                console.log("Removed from LP holders list:");
                console.log(user);
            }

            emit LPSharesUpdated(user, newShares);
        }
    }
    
    // 获取所有LP持有者列表
    function getLPHolders() external view returns (address[] memory) {
        return lpHoldersList;
    }
    
    // 批量更新用户LP份额
    function batchUpdateLPShares(address[] calldata users) external {
        for (uint i = 0; i < users.length; i++) {
            updateUserLPShares(users[i]);
        }
    }
    
    // 获取用户占总LP的百分比(精度为1e18)
    function getUserLPPercentage(address user) external view returns (uint256) {
        if (totalTrackedLPShares == 0 || excludedFromTracking[user]) return 0;

        return userLPShares[user].mul(1e18).div(totalTrackedLPShares);
    }
    
    // 根据LP份额分配奖励(由DeflationModule调用)
    function distributeRewards(uint256 totalRewardAmount) external {
        require(
            msg.sender == address(ydtToken) ||
                msg.sender == ydtToken.owner() ||
                msg.sender == address(ydtToken.getDeflationModule()),
            "Only authorized modules can call"
        );

        // 触发奖励分配事件
        emit RewardsDistributed(totalRewardAmount, block.timestamp);
    }
    
    // 计算用户应得奖励
    function calculateUserReward(
        address user,
        uint256 totalRewardAmount
    ) public view returns (uint256) {
        if (
            totalTrackedLPShares == 0 ||
            excludedFromTracking[user] ||
            userLPShares[user] == 0
        ) {
            return 0;
        }

        return
            totalRewardAmount.mul(userLPShares[user]).div(totalTrackedLPShares);
    }
    
    // 在添加或移除流动性时调用此函数更新状态
    function onLiquidityChange(address user) external {
        // 此函数可由Router或其他合约调用来同步状态
        updateUserLPShares(user);
    }
    
    // 内部函数：添加地址到持有者列表
    function _addToHoldersList(address user) private {
        if (!isInHoldersList[user]) {
            lpHoldersList.push(user);
            isInHoldersList[user] = true;
        }
    }
    
    // 内部函数：从持有者列表中移除地址
    function _removeFromHoldersList(address user) private {
        if (isInHoldersList[user]) {
            // 查找用户在数组中的位置
            for (uint i = 0; i < lpHoldersList.length; i++) {
                if (lpHoldersList[i] == user) {
                    // 将最后一个元素移到当前位置，然后删除最后一个元素
                    lpHoldersList[i] = lpHoldersList[lpHoldersList.length - 1];
                    lpHoldersList.pop();
                    break;
                }
            }
            isInHoldersList[user] = false;
        }
    }

    // 处理转账中的LP追踪 - 此函数在YDTMainContract中调用
    function handleTransferLpTracking(address sender, address recipient, uint256 amount) external {
        address pancakePair = ydtToken.getPancakePair();
        console.log("handleTransferLpTracking - Address:");
        console.log(sender);
        console.log(recipient);
        console.log(amount);
        console.log(pancakePair);
        this.processLPOperations(5);
        // 检查是否与LP交易对相关的转账
        if (sender == pancakePair) {
            // 从交易对转出 - 移除流动性
            recordLPOperation(recipient, false, amount);
        } else if (recipient == pancakePair) {
            // 转入交易对 - 添加流动性
            recordLPOperation(sender, true, amount);
        }
    }

    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "LPHolderTrackingModule: Only main contract can call");
        require(to != address(0), "LPHolderTrackingModule: Invalid recipient address");
        require(amount > 0, "LPHolderTrackingModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "LPHolderTrackingModule: Insufficient balance");
        
        token.transfer(to, amount);
    }
 
}
