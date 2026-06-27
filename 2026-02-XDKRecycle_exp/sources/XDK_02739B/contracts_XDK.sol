// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import {Helper} from "./Helper.sol";
import {BaseGpc} from "./BaseGpc.sol";
import {DEAD_WALLET,_GPC,_ROUTER} from './Const.sol';
import "./ExcludedFromFeeList.sol";
import "./ITokenReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


contract XDK is ExcludedFromFeeList,BaseGpc,ReentrancyGuard,ERC20{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // ========================= 核心常量 =========================
    // 手续费比例（千分比）
    uint256 public constant BURN_FEE_RATE = 10; // 1% 销毁
    uint256 public constant BLACK_HOLE_FEE_RATE = 10; // 1% 黑洞LP池
    uint256 public constant REWARD_FEE_RATE = 10; // 1% 分红池（合约自身）
    uint256 public constant TOTAL_TRADE_FEE = 30; // 3% 总交易费率
    uint256 public constant SELL_RECYCLE_RATE = 100; // 卖单回收10%
    uint256 public constant MAX_RECYCLE_RATE = 100; //最大回收底池10%

    // 分红相关常量
    uint256 public constant REWARD_MIN_HOLD_PECENT = 10; //分红最少占比 1%；

    // ========================= 状态变量 =========================

    mapping(address => bool) public isStop; // 地址冻结开关

    uint40 public immutable recycleColdTime = 1 days; // 回收底池冷却时间
    uint256 public pendingFees; // 暂存手续费
    uint256 public immutable maxBurnFee; // 最大销毁量

    // 股东与分红相关
    address[] public shareholders; // 股东列表（LP持有者）
    mapping(address=>uint256) lpAmounts;
    address internal lastUser;
    mapping(address => bool) private isShareholder;
    mapping (address => uint256) lpIndex;

    uint256 public currentRewardIndex; // 分红批次索引
    uint256 public rewardPoolBalance; // 分红池余额（合约内）
    uint256 public lastRecycleTime; // 上次回收底池时间
    uint256 public thisRecycleMaxBalance; // 本次回收最大余额
    uint256 public thisRecycleBalance;


    uint256 public immutable _rewardGas = 1000000;

    // 打新相关
    uint40 public launchedAtTimestamp;   // 开始时间
    bool public isStart;    //是否开启交易

    IERC20 internal immutable gpc;



    // ========================= 事件 =========================
    event LaunchCompleted(uint256 timestamp);

    event UserPermit(address user,bool status);
  
    event TradeFeesDistributed(
        address indexed sender,
        address indexed recipient,
        uint256 burnAmount,
        uint256 blackHoleAmount,
        uint256 rewardAmount
    );
    event SellRecycledFromBlackHole(
        uint256 sellAmount,
        uint256 recycleAmount,
        bool success
    );
    event LpOperationFeeDeducted(
        address indexed user,
        bool isAddLp,
        uint256 feeAmount
    );
    event RewardsDistributed(
        uint256 batchIndex,
        uint256 processedCount,
        uint256 totalDistributed,
        uint256 remainingBalance
    );
    event ShareholderAdded(address indexed shareholder);

    event ContractNotified(
        address indexed sender,
        address indexed reciever,
        uint256 amount,
        bool success
    );

    event ErrorMessage(string message);


    // ========================= 构造函数 =========================
    constructor(
        string memory Name,
        string memory Symbol,
        uint256 TotalSupply,
        uint256 _maxBurnFee,
        address reciveAddress
    ) ERC20(Name, Symbol) {
        // 铸造初始代币
        maxBurnFee = _maxBurnFee * 10 ** decimals();
        // 排除免手续费地址
        excludeFromFee(address(0));
        excludeFromFee(DEAD_WALLET);
        excludeFromFee(address(this));
        excludeFromFee(reciveAddress);
        updateShareholder(reciveAddress);
        _mint(reciveAddress, TotalSupply * 10 ** decimals());
        gpc = IERC20(_GPC);
        _approve(reciveAddress, _ROUTER,  type(uint256).max);
        _approve(address(this), _ROUTER,  type(uint256).max);   
        gpc.approve(_ROUTER, type(uint256).max);
        
    }

 


    // ========================= 权限函数 =========================
    function launch() public onlyOwner {
        require(!isStart, "Already launched");
        launchedAtTimestamp = uint40(block.timestamp);
        isStart = true;
      
        emit LaunchCompleted(launchedAtTimestamp);
    }


    function setAddressFreeze(address account, bool status) external onlyOwner{
        isStop[account] = status;   
        emit UserPermit(account,status);
    }


    // ========================= 核心逻辑：转账+操作判断+手续费 =========================
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override  {
        // 基础校验（保留不变）
        require(
            sender != address(0) && recipient != address(0),
            "Zero address"
        );
        require(amount > 0, "Zero amount");
        require(!isStop[sender] && !isStop[recipient], "Address stopped");
       
        address pairAddress = uniswapV2Pair;

        // 免手续费场景（保留不变）
        if (
            _isExcludedFromFee[sender] ||
            _isExcludedFromFee[recipient] || inSwapAndLiquify
        ) {
            super._transfer(sender, recipient, amount);
            _afterTokenTransferSelf(sender,recipient,amount);
            return;
        }
        
        //uint256 transferAmount = amount;
         bool isBuy = false;
        bool isSell = false;
        address user = address(0); // 操作关联的用户（用于更新股东）

        // 1. 判断买卖单（非LP操作，保留原有逻辑核心）
        if (isPair(recipient)) {
            isSell = true;
            user = sender;
            pairAddress = recipient;
        } else if (isPair(sender)) {
            isBuy = true;
            user = recipient;
            pairAddress = sender;
        }
        if (isBuy || isSell) {
           
            handlerTranscation(sender,recipient,amount,user,isSell);
          
        }else{
            // 非买卖，直接转账
            super._transfer(sender, recipient, amount);
            _afterTokenTransferSelf(sender,recipient,amount);
            return;
        }
   
    }

    function handlerTranscation(address sender,
        address recipient,
        uint256 transferAmount,address user,bool isSell) internal {
        uint256 currentBurn = balanceOf(DEAD_WALLET);
        require(isStart,'not started');
            // 买卖操作：防巨鲸，最大流通量的10%
            (uint112 reverseThis,)=getReverses();
            require(transferAmount < reverseThis/10,'max cap');
            // 买卖操作：扣除3%手续费
            uint256 totalFee = (transferAmount * TOTAL_TRADE_FEE) / 1000;
            uint256 burnAmount = 0;
            if (totalFee > 0) {
                transferAmount -= totalFee;
                burnAmount = (totalFee * BURN_FEE_RATE) /
                    TOTAL_TRADE_FEE;
                uint256 blackHoleAmount = (totalFee * BLACK_HOLE_FEE_RATE) /
                    TOTAL_TRADE_FEE;
                uint256 rewardAmount = totalFee - burnAmount - blackHoleAmount;

                if(currentBurn >=maxBurnFee){
                    if(burnAmount>0){
                        blackHoleAmount += burnAmount; 
                        burnAmount=0;
                    }
                }else{
                    if(currentBurn + burnAmount > maxBurnFee){
                        uint256 remaining = maxBurnFee - currentBurn; // 剩余可燃烧额度
                        uint256 toBurn = remaining; // 本次实际燃烧量（不超过剩余额度）
                        uint256 excess = burnAmount - toBurn; // 超额部分（需转入黑洞）

                        if (toBurn > 0) {
                            super._transfer(sender, DEAD_WALLET, toBurn);
                        }
                        if (excess > 0) {
                            blackHoleAmount += excess; // 超额部分进入黑洞
                        }
                        burnAmount = toBurn; // 更新burnAmount为实际燃烧量
                    
                    }else{
                        super._transfer(sender, DEAD_WALLET, burnAmount);
                    }
                }
                
            
                if (blackHoleAmount > 0) {
                    // 兑换打入底池的数量
                    super._transfer(sender, address(this), blackHoleAmount);
                    pendingFees += blackHoleAmount;

                }
                if (rewardAmount > 0) {
                    super._transfer(sender, address(this), rewardAmount);
                    rewardPoolBalance += rewardAmount;
                }
                emit TradeFeesDistributed(
                    sender,
                    recipient,
                    burnAmount,
                    blackHoleAmount,
                    rewardAmount
                );
            }
            // addLP后用户LP余额增加，更新股东（在转账后执行，因LP代币在转账后发放）
            updateShareholder(user);

            // ====================== 后续逻辑（保留不变，仅适配isLpAdd） =======================
            if (isSell) {
                
                _processPendingFees();
                
                if (currentBurn + burnAmount <= maxBurnFee && isMainPair(recipient)) {             
                    _recycleFromBlackHoleOnSell(transferAmount);
                }   
                if (rewardPoolBalance > 0) {
                    distributeRewardsBatch();
                }
            }
             // ====================== 执行最终转账（保留不变） =======================
            super._transfer(sender, recipient, transferAmount);
    }

    // ========================= 股东管理逻辑 =========================
    function updateShareholder(address user) internal virtual nonReentrant{
        if (user == DEAD_WALLET || user == address(0) || user == address(this))
            return;  
        // 未在列表且未满额：添加股东
      
        if(user !=address(0)){
            IERC20 lp = IERC20(uniswapV2Pair);
            uint256 balance =   lp.balanceOf(lastUser);     
            if(balance>0){
                lpAmounts[lastUser] = balance;
                if(!isShareholder[lastUser]){
                    isShareholder[lastUser] = true; // 1-based索引
                    shareholders.push(lastUser);
                    lpIndex[lastUser]=shareholders.length-1;
                    emit ShareholderAdded(lastUser);
                }
            }else{
                if(isShareholder[lastUser]){
                    delete isShareholder[lastUser];
                    uint256 index = lpIndex[lastUser];
                    address latest = shareholders[shareholders.length-1];
                    shareholders[index]=latest;
                    lpIndex[latest]=index;
                    shareholders.pop();
                    lpIndex[lastUser]=0;
                }
            }
            
        }
        lastUser = user;

       
    }

    event RewardsDistributedSim(address user, uint256 rewardPoolBalance,uint256 reward);


    // ========================= 分红逻辑（按LP比例分批分发）=========================
    function distributeRewardsBatch() internal virtual nonReentrant{
        // 基础校验
        require(rewardPoolBalance > 0, "No rewards available");
        IERC20 lp = IERC20(uniswapV2Pair);
        uint256 totalLpSupply = lp.totalSupply();
        uint256 deadLp = lp.balanceOf(DEAD_WALLET) + lp.balanceOf(address(0));
        uint256 totalLp = totalLpSupply - deadLp;
        uint256 distributableThed= totalLp * REWARD_MIN_HOLD_PECENT / 1000;
        uint256 shareholderCount = shareholders.length;
        if (totalLp == 0 || shareholderCount == 0) return;

        // 可分发金额（取合约余额与记录余额的最小值）
        uint256 distributable = rewardPoolBalance;
        if (distributable == 0) return;

        // Gas检查
        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();
        uint256 totalDistributed=0;

        while (gasUsed < _rewardGas && iterations < shareholderCount) {
            if (currentRewardIndex >= shareholderCount) {
                currentRewardIndex = 0;
            }
            address shareholder = shareholders[currentRewardIndex];
            uint256 userLp = lp.balanceOf(shareholder);
            if (userLp < distributableThed) {
                iterations++;
                currentRewardIndex++; // 即使跳过，也要更新索引，避免重复检查
                gasUsed += (gasLeft - gasleft()); // 累加本次迭代消耗（即使跳过）
                gasLeft = gasleft();
                continue;
            }
            uint256 permit =  lpAmounts[shareholder] * 5 /100;

            if(lpAmounts[shareholder] > userLp || userLp - lpAmounts[shareholder] >= permit){
                iterations++;
                currentRewardIndex++; // 即使跳过，也要更新索引，避免重复检查
                lpAmounts[shareholder]=userLp;
                gasUsed += (gasLeft - gasleft()); // 累加本次迭代消耗（即使跳过）
                gasLeft = gasleft();
                continue;
            }
            uint256 reward = (distributable * lpAmounts[shareholder]) / totalLp;
            if(lpAmounts[shareholder] !=userLp){
                lpAmounts[shareholder]=userLp;
            }
            if (reward == 0) {
                currentRewardIndex++;
                iterations++;
                
                gasUsed += (gasLeft - gasleft());
                gasLeft = gasleft();
                continue;
            }
            // 执行分红转账
            super._transfer(address(this), shareholder, reward);
            emit RewardsDistributedSim(shareholder,distributable,reward);
            totalDistributed += reward;
            iterations++;
            currentRewardIndex++;
            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
        }
        // 更新状态
        rewardPoolBalance -= totalDistributed;
        if (currentRewardIndex >= shareholderCount) currentRewardIndex = 0;

        emit RewardsDistributed(
            currentRewardIndex,
            iterations,
            totalDistributed,
            rewardPoolBalance
        );
    }

    // ========================= 卖单回收逻辑 =========================
    function _recycleFromBlackHoleOnSell(uint256 sellAmount
    ) internal virtual  {
        if (lastRecycleTime + recycleColdTime < block.timestamp) {
            lastRecycleTime = block.timestamp;
            thisRecycleMaxBalance =
                (balanceOf(uniswapV2Pair) * MAX_RECYCLE_RATE) /
                1000;
            thisRecycleBalance = 0;
            return;
        }
        if(thisRecycleBalance >=thisRecycleMaxBalance){
            return;
        }

        
        uint256 targetXdk = sellAmount * SELL_RECYCLE_RATE / 1000;

        // 计算回收量：卖出量的10%
        // 2. 获取LP合约数据（黑洞持有的LP数量、LP总供应量、LP中的XDK储备）
        IPancakePair lpContract = IPancakePair(uniswapV2Pair);
        uint256 blackHoleLp = lpContract.balanceOf(DEAD_WALLET); // 黑洞持有的LP数量
        uint256 totalLpSupply = lpContract.totalSupply(); // LP总供应量
        uint256 reserveXdk = balanceOf(uniswapV2Pair); // LP中的XDK储备量

        // 边界条件：LP总供应量为0或黑洞无LP，无法回收
        if (totalLpSupply == 0 || blackHoleLp == 0 || reserveXdk == 0) {
            emit SellRecycledFromBlackHole(sellAmount, 0, false);
            return;
        }
        // 3. 计算黑洞LP中实际包含的XDK数量
        // 公式：黑洞LP含有的XDK =（黑洞LP数量 / 总LP供应量）* LP中的XDK储备
        uint256 xdkInBlackHoleLp = (blackHoleLp * reserveXdk) / totalLpSupply;

        // 4. 实际回收量 = min(目标回收量, 黑洞LP中可提取的XDK)
        uint256 actualRecycleXdk = targetXdk > xdkInBlackHoleLp
            ? xdkInBlackHoleLp
            : targetXdk;
        if (actualRecycleXdk == 0) {
            emit SellRecycledFromBlackHole(sellAmount, 0, false);
            return;
        }
       
        // 新增：计算其他LP的总缩水金额（需补到分红池的量）
        uint256 otherLpTotalShrink = (actualRecycleXdk *
            (reserveXdk - xdkInBlackHoleLp)) / reserveXdk;
        if (actualRecycleXdk == 0 || otherLpTotalShrink == 0) {
            emit SellRecycledFromBlackHole(sellAmount, 0, false);
            return;
        }
        thisRecycleBalance =thisRecycleBalance + actualRecycleXdk + otherLpTotalShrink;
       
        // 5. 执行回收（从LP合约中提取对应XDK并销毁）
        // 注意：需先通过LP合约提取XDK，这里简化为直接从LP储备中转移（实际需调用removeLiquidity）
        bool success = false;

        // 实际场景中需先将黑洞LP转移到合约，再移除流动性获取XDK，最后销毁
        // 此处简化为直接从LP合约转移XDK至死地址（需LP合约授权）
        super._transfer(uniswapV2Pair, DEAD_WALLET, actualRecycleXdk);
        super._transfer(uniswapV2Pair, address(this), otherLpTotalShrink);
        rewardPoolBalance += otherLpTotalShrink;
        success = true;
        lpContract.sync();
        emit SellRecycledFromBlackHole(
            sellAmount,
            actualRecycleXdk,
            success
        );
    }

    // ========================= 辅助函数 =========================
    function _processPendingFees() internal virtual lockTheSwap{
        // 转成LP
        if(pendingFees>0){
            swapAndLiquify(pendingFees);
            pendingFees = 0;
        }     
    }



    function swapTokenForGPC(uint256 tokenAmount, address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](2);
             path[0] = address(this);
            path[1] = _GPC;
            
           
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }


    function addLiquidity(uint256 tokenAmount, uint256 gpcAmount) internal virtual{
        uniswapV2Router.addLiquidity(
            address(this),
            _GPC,
            tokenAmount,
            gpcAmount,
            0,
            0,
            DEAD_WALLET,
             block.timestamp+300
        );
    }

    function swapAndLiquify(uint256 tokens) internal virtual {
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;
        uint256 initialBalance = gpc.balanceOf(address(this));
        bool result = swapTokenForGPC(half, address(distributor));
        if(result){
            gpc.safeTransferFrom(address(distributor),
                address(this),
                gpc.balanceOf(address(distributor)));
            uint256 newBalance = gpc.balanceOf(address(this)) - initialBalance;
            addLiquidity(otherHalf, newBalance);
        }
    }

   function _afterTokenTransferSelf(
    address from,
    address to,
    uint256 amount
) internal virtual {

    // 用 try 包裹低级别 call（等价于 call 的高层级处理）
   bool isNotificationSuccess = notifyContract(from, to, amount);
   emit ContractNotified(from, to, amount, isNotificationSuccess);
   
}
event NotificationAttempt(
    address indexed receiver,
    bool isContract,       // 是否为合约（codeSize > 0）
    bool isSmartWallet,    // 是否为智能钱包（合约的子集）
    bool callSucceeded     // 通知是否成功（仅普通合约有意义）
);


// 辅助函数：将低级别 call 封装为可被 try/catch 捕获的函数
function notifyContract(address from, address to, uint256 amount) internal returns (bool) {
     uint256 codeSize;
    assembly { codeSize := extcodesize(to) }
    if (codeSize == 0) return true; // 非合约地址，无需通知


    // 4. 普通智能合约 → 用call尝试通知onTokenReceived
    (bool success, ) = to.call(
        abi.encodeWithSignature("onTokenReceived(address,address,uint256)", from, to, amount)
    );
    // 无论success为true/false，均不revert，仅记录
    emit NotificationAttempt(to, true, false, success);
    return success;

}


    // ========================= 视图函数 =========================
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardPoolBalance;
    }

    function getBlackHoleLpBalance() external view returns (uint256) {
        return DEAD_WALLET == address(0) ? 0 : balanceOf(DEAD_WALLET);
    }

    function getUserLPInfo(address user) external view returns(uint256,uint256,uint256){
        IERC20 lp = IERC20(uniswapV2Pair);
        uint256 totalLpSupply = lp.totalSupply();
        uint256 deadLp = lp.balanceOf(DEAD_WALLET) + lp.balanceOf(address(0));
        uint256 totalLp = totalLpSupply - deadLp;
        return (totalLpSupply,totalLp,lp.balanceOf(user));
    }

    function getPendingFees() external view returns (uint256) {
        return pendingFees;
    }

    function getShareholderCount() external view returns (uint256) {
        return shareholders.length;
    }


    function getReverses() public view returns(uint112, uint112){
        address token0 = IPancakePair(uniswapV2Pair).token0();
        //address token1 = IPancakePair(uniswapV2Pair).token1();

        (uint112 reserve0, uint112 reserve1,)=IPancakePair(uniswapV2Pair).getReserves();

        // 2. 判断哪个代币是自己的代币，确定对应的储备量
        if(token0==address(this)){
            return (reserve0,reserve1);
        }else{
            return (reserve1,reserve0);
        }
    
    }


    


}
