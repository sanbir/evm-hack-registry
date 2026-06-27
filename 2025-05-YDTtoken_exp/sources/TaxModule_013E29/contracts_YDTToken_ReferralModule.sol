// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./YDTMainContract.sol"; 
import "hardhat/console.sol";
contract ReferralModule {
    using SafeMath for uint256;
    YDTMainContract public immutable ydtToken;
    event ReferralRewardReceived(address indexed user,address indexed currentRef, uint256 amount);
    // 推荐状态枚举
    enum ReferralStatus {
        None,        // 0: 无推荐关系
        Pending,     // 1: A向B转账，等待B确认
        Confirmed    // 2: B已确认，关系建立
    }

    // 推荐数据结构
    struct Referral {
        address potentialReferrer;  // 潜在推荐人（B）
        uint256 timestamp;          // A首次转账时间
        uint256 amount;             // A转账金额
        ReferralStatus status;      // 当前状态
    }

    // 用户 => 推荐信息
    mapping(address => Referral) public referrals;

    // 用户 => 推荐人数
    mapping(address => uint256) public referralCount;
    
    // 触发推荐关系的百分比（0.1 = 10%）
    uint256 public constant REFERRAL_TRIGGER_PERCENT = 10; // 10%
    
    // 推荐奖励比例（10% = 1000，1% = 100）
    uint256 public constant REFERRAL_REWARD_RATE = 1000; // 10%
    
    // 双向转账确认时间窗口（3天）
    uint256 public constant CONFIRMATION_WINDOW = 3 days;

    // 事件
    event ReferralInitiated(address indexed user, address indexed potentialReferrer, uint256 amount);
    event ReferralConfirmed(address indexed referrer, address indexed newUser);
    event ReferralExpired(address indexed user, address indexed potentialReferrer);

    // 访问控制修饰符
    modifier onlyMainContract() {
        require(msg.sender == address(ydtToken), "ReferralModule: Only main contract can call");
        _;
    }

    constructor(address _ydtToken) {
        ydtToken = YDTMainContract(_ydtToken);
    }
    // 在转账时处理推荐关系 - 改为内部函数
    function handleReferral(address sender, address recipient, uint256 amount) internal  returns (bool) {
 
 
            console.log('referrals[recipient].status == ReferralStatus.Pending',referrals[recipient].status == ReferralStatus.Pending);
            console.log('referrals[recipient].potentialReferrer == sender',referrals[recipient].potentialReferrer == sender);
            
            if(referrals[recipient].status == ReferralStatus.Pending && referrals[recipient].potentialReferrer == sender){
                if(block.timestamp <= referrals[recipient].timestamp + CONFIRMATION_WINDOW){
                    referrals[recipient].status = ReferralStatus.Confirmed;
                    // 增加推荐人的推荐计数
                    referralCount[sender]+=1;
                    emit ReferralConfirmed(recipient, sender);
                    return true;
                }else{
                    referrals[sender].status = ReferralStatus.None;
                    emit ReferralExpired(sender, recipient);
                    return false;
                }
            }
            
            referrals[sender] = Referral({
                potentialReferrer: recipient,
                timestamp: block.timestamp,
                amount: amount,
                status: ReferralStatus.Pending
            });
            
            emit ReferralInitiated(sender, recipient, amount);
            return true;
  
    }

    // 由主合约在_transfer中调用的函数 - 添加访问控制保护
    function handleTransfer(address sender, address recipient, uint256 amount) external onlyMainContract {
        // 动态获取触发金额并比较
        if (amount == getReferralTriggerAmount()) {
           handleReferral(sender, recipient, amount);  // 改为内部调用，去掉 this.
        }          
    }
    
    // 计算推荐奖励
    function calculateReferralBonus(address user, uint256 amount) external view returns (uint256) {
        if (referrals[user].status != ReferralStatus.Confirmed) return 0;
        address referrer = referrals[user].potentialReferrer;
        if (referrer == address(0)) return 0;
        // 计算奖励：amount * REFERRAL_REWARD_RATE / 10000
        return amount.mul(REFERRAL_REWARD_RATE).div(10000);
    }

    // 获取触发推荐关系的实际金额（0.1个代币）
    function getReferralTriggerAmount() public view returns (uint256) {
        uint256 decimals = ydtToken.decimals();
        return 10**(decimals - 1); // 0.1 * 10^decimals
    }

    // 查询用户推荐状态
    function getReferralStatus(address user) external view returns (
        address potentialReferrer,
        uint256 timestamp,
        uint256 amount,
        ReferralStatus status,
        uint256 remainingTime
    ) {
        Referral memory referral = referrals[user];
        remainingTime = 0;
        
        if (referral.status == ReferralStatus.Pending) {
            remainingTime = referral.timestamp + CONFIRMATION_WINDOW - block.timestamp;
            if (remainingTime > 0) {
                remainingTime = 0;
            }
        }
        
        return (
            referral.potentialReferrer,
            referral.timestamp,
            referral.amount,
            referral.status,
            remainingTime
        );
    }
    // 分配推荐奖励 - 修正版：每个用户根据自己的推荐计数获得对应代数的分红
    function distributeReferralReward(address user, uint256 usdtAmount,uint256 refAmount) external {
        // 确保调用者是主合约或流动性模块
        YDTMainContract main = ydtToken;
        require(
            msg.sender == address(main) || 
            msg.sender == address(main.getLiquidityModule()),
            "ReferralModule: Unauthorized, only main contract or liquidity module can call"
        );
        
        address currentRef = referrals[user].potentialReferrer;
        if (currentRef == address(0)) return;
        
        // 获取USDT合约
        IERC20 usdtContract = IERC20(ydtToken.getUSDT());
        
        // 最大分配8代，每个用户根据自己的推荐计数和与触发用户的代差独立判断
        uint256 generation = 1; // 从第1代开始计数
        
        for (uint256 i = 0; i < 8; i++) {
            if (currentRef == address(0)) break;
            
            // 检查当前推荐人的推荐计数
            uint256 currentRefCount = referralCount[currentRef];
            
            // 根据推荐计数决定该用户能获得多少代分红
            uint256 maxGenerationsForCurrentRef = 0;
            if (currentRefCount >= 3) {
                maxGenerationsForCurrentRef = 8;
            } else if (currentRefCount == 2) {
                maxGenerationsForCurrentRef = 5;
            } else if (currentRefCount == 1) {
                maxGenerationsForCurrentRef = 3;
            } else {
                // 推荐计数为0，不给奖励，但继续检查下一个用户
                currentRef = referrals[currentRef].potentialReferrer;
                generation++;
                continue;
            }
            
            // 判断当前代差是否在该用户的分红范围内
            if (generation <= maxGenerationsForCurrentRef) {
                uint256 refReward = refAmount.mul(20).div(1000); // 每代2%
                
                // 确保有足够的USDT余额
                if (usdtContract.balanceOf(address(this)) >= refReward) {
                    usdtContract.transfer(currentRef, refReward);
                    console.log(refAmount);
                    console.log("distributeReferralReward",user,currentRef, refReward);
                    //触发事件 推荐人收到推荐奖励
                    emit ReferralRewardReceived(user,currentRef, refReward);
                }
            }
            
            // 移动到下一个推荐人
            currentRef = referrals[currentRef].potentialReferrer;
            generation++;
        }
    }

    /**
     * @dev 管理员紧急提取功能 - 只允许主合约调用
     * @param tokenAddress 代币地址
     * @param to 接收地址
     * @param amount 提取数量
     */
    function withdrawToken(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == address(ydtToken), "ReferralModule: Only main contract can call");
        require(to != address(0), "ReferralModule: Invalid recipient address");
        require(amount > 0, "ReferralModule: Amount must be greater than zero");
        
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "ReferralModule: Insufficient balance");
        
        token.transfer(to, amount);
    }
 
}