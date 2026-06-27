// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
   
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event InterestRateChanged(uint256 newRate);
}

abstract contract ReentrancyGuard {

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

// 安全数学库
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function factory() external pure override returns (address);
    function WETH() external pure override returns (address);
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
            uint256 amountOutMin,
            address[] calldata path,
            address to,
            uint256 deadline
        ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint reserveA, uint reserveB, uint32 blockTimestampLast);
}

contract trading is ReentrancyGuard {
    using SafeMath for uint256;
    address owner;

    IUniswapV2Router02 public pancakeSwapRouter;

    //沽空结构体
    struct SellOrder {
        uint256 usdtShorted;//沽空头寸
        uint256 margin;//保证金
        uint256 tokenAmount;//卖出代币数量
        uint256 priceAtTimeOfSale;//卖出价格
        address user;//订单用户
        bool isActive;//是否有效
        uint256 openTime;//开仓时间
        uint256 closeTime;//到期时间
    }

    //质押结构体
    struct record { 
        uint256 stakeTime; 
        uint256 stakeAmt; 
        uint256 lastUpdateTime; 
        uint256 accumulatedInterestToUpdateTime; 
        uint256 amtWithdrawn; 
    }

	uint256 public numberOfAddressesCurrentlyStaked = uint256(0);
	uint256 public interestTax = uint256(100000); //提取利息税
	uint256 public totalWithdrawals = uint256(0);
    uint256 public expiredNotClosedUSDT; //统计未平仓USDT
    uint256 public lastProcessedOrderId = 0; // 游标跟踪最后处理的订单ID
    uint256 public batchSize = 20; // 每批处理的订单数量

    uint256 public nextSellOrderId; //下一个挂卖编号
    uint256 public dailyInterestRate = uint256(24); // 换算价格后约等于每天0.4%借出利率，基准值100 0000
    uint256 constant INTEREST_PER_USDT_PER_SECOND = 578; // 代表每做空1U每秒支付利息：0.0000000578，≈0.5%每天

    address public pairAddress; //资金池地址
    address public constant feeAddress = 0x000000000000000000000000000000000000dEaD; //黑洞销毁地址
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955; // USDT地址
    address public token;
    
    mapping(address => record) public informationAboutStakeScheme;
	mapping(uint256 => address) public addressStore;
    mapping(uint256 => bool) public activeOrders; //活跃订单集合
    
    mapping(uint256 => SellOrder) public sellOrders;
    mapping(address => uint256[]) public ownerToOrderIds;

    event SellOrderPlaced(uint256 indexed orderId, address indexed user, uint256 amount);
    event BuyOrderPlaced(uint256 indexed orderId, address indexed user, uint256 usdtSpent, uint256 tokensBoughtBack);
    event MarginAdded(uint256 indexed orderId, address indexed user, uint256 addedMargin, uint256 newCloseTime);
    event Staked (address indexed account);
	event Unstaked (address indexed account);
    event InterestPaid(address indexed account, uint256 interestAmount);

    constructor(address _token) {

        token = _token;
        owner = msg.sender;
        pancakeSwapRouter = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    }

    function changeOwner(address _newOwner) public onlyOwner {
		owner = _newOwner;
	}

	modifier onlyOwner() {
		require(msg.sender == owner);
		_;
	}

    // 查询某地址拥有的做空订单
    function getOrderIdsOwnedBy(address user) public view returns (uint256[] memory) {
        return ownerToOrderIds[user];
    }

    // 定义一个函数来获取流动性池中的USDT和代币储备
    function getReserves() internal view returns (uint reserveUSDT, uint reserveToken) {
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair(pairAddress).getReserves();
        if (USDT < token) {
            reserveUSDT = reserve0;
            reserveToken = reserve1;
        } else {
            reserveUSDT = reserve1;
            reserveToken = reserve0;
        }
    }

    // 用户沽空代币
    function placeSellOrder(uint256 usdtAmount, uint256 margin, uint256 minUsdtReceived) public nonReentrant {
        require(IERC20(USDT).transferFrom(msg.sender, address(this), usdtAmount + margin), "USDT transfer failed");

        // 调用函数获取流动性池储备
        (uint reserveUSDT, uint reserveToken) = getReserves();

        // 计算出售代币可获得的USDT数量
        uint256 tokenAmount = calculateTokenAmountToSell(usdtAmount, reserveUSDT, reserveToken);

        // 授权PancakeSwap路由器合约从合约中转出计算出的代币数量
        require(IERC20(token).approve(address(pancakeSwapRouter), tokenAmount), "Approve failed");

        // 记录交换前的代币余额
        uint256 initialTokenBalance = IERC20(token).balanceOf(address(this));

        // 设置交易路径从代币到USDT
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDT;

        // 执行交换，卖出计算出的代币数量
        pancakeSwapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount, // 要交换的代币数量
            minUsdtReceived, // 最小接受的USDT数量
            path,
            address(this), // 确保USDT返回到合约地址
            block.timestamp + 300 // 交易截止时间
        );

        // 记录交换后的代币余额
        uint256 finalTokenBalance = IERC20(token).balanceOf(address(this));

        // 实际卖出的代币数量
        uint256 actualTokenSold = initialTokenBalance - finalTokenBalance;

        // 创建做空订单
        uint256 orderId = nextSellOrderId++;

        uint256 secondsExtended = margin.mul(1e10).div(usdtAmount.mul(INTEREST_PER_USDT_PER_SECOND));
        uint256 closeTime = block.timestamp + secondsExtended;

        sellOrders[orderId] = SellOrder({
            usdtShorted: usdtAmount,
            margin: margin,
            tokenAmount: actualTokenSold, // 实际卖出的代币数量
            priceAtTimeOfSale: calculatePrice(usdtAmount, actualTokenSold),
            user: msg.sender,
            isActive: true,
            openTime: block.timestamp,
            closeTime: closeTime
        });

        // 记录用户的沽空订单
        ownerToOrderIds[msg.sender].push(orderId);
        activeOrders[orderId] = true;
        emit SellOrderPlaced(orderId, msg.sender, actualTokenSold);
    }

    // 计算价格的内部函数
    function calculatePrice(uint256 usdtAmount, uint256 tokenAmount) internal pure returns (uint256) {
        return (usdtAmount.mul(1e18)).div(tokenAmount);
    }

    // 计算需要卖出的代币数量，以在给定流动性池中获得特定的USDT数量
    function calculateTokenAmountToSell(uint256 usdtAmount, uint256 reserveUSDT, uint256 reserveToken) internal pure returns (uint256) {
        require(usdtAmount < reserveUSDT, "Insufficient liquidity.");
        uint256 tokenAmount = (reserveToken * usdtAmount) / (reserveUSDT - usdtAmount);
        return tokenAmount + 1; // 加一以确保在考虑滑点后仍能实现至少usdtAmount的USDT
    }

    // 计算指定做空订单的累计利息
    function calculateInterest(uint256 orderId) public view returns (uint256) {
        require(orderId < nextSellOrderId, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.isActive, "Order is not active");

        uint256 secondsElapsed = block.timestamp - order.openTime; // 计算自开仓以来过去了多少秒
        uint256 interest = order.usdtShorted.mul(secondsElapsed).mul(INTEREST_PER_USDT_PER_SECOND).div(1e12); // 使用INTEREST_PER_USDT_PER_SECOND来计算利息

        return interest;
    }

    // 预测平仓后用户可以收到多少USDT（包含利息）
    function calculateCloseReturn(uint256 orderId) public view returns (uint256) {
        require(orderId < nextSellOrderId, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.isActive, "Order is not active");

        uint256 interest = calculateInterest(orderId); // 计算累计利息
        if (order.margin < interest) {
            return 0; // 如果保证金不足以覆盖利息，无法进行平仓
        }
        uint256 remainingMargin = order.margin.sub(interest); // 扣除利息后的剩余保证金

        // 调用函数获取流动性池储备
        (uint reserveUSDT, uint reserveToken) = getReserves();

        // 考虑滑点后的USDT成本
        uint256 tokensToBuyBack = order.tokenAmount;
        uint256 usdtNeeded = reserveUSDT * tokensToBuyBack / (reserveToken - tokensToBuyBack);

        // 计算盈亏并预测返回金额
        if (usdtNeeded <= order.usdtShorted) {
            uint256 profit = order.usdtShorted.sub(usdtNeeded);
            return order.usdtShorted.add(profit).add(remainingMargin); // 盈利情况下，返回做空头寸、盈利和剩余保证金
        } else {
            uint256 deficit = usdtNeeded.sub(order.usdtShorted);
            if (remainingMargin >= deficit) {
                // 如果剩余保证金足以覆盖亏损
                remainingMargin = remainingMargin.sub(deficit);
                return order.usdtShorted.add(remainingMargin); // 返回剩余保证金加上做空头寸的资金
            } else {
                // 如果保证金不足以覆盖亏损，检查做空头寸是否足以支付剩余亏损
                uint256 remainingDeficit = deficit.sub(remainingMargin);
                if (order.usdtShorted >= remainingDeficit) {
                    return order.usdtShorted.sub(remainingDeficit); // 返回做空头寸中剩余的部分
                } else {
                    return 0; // 做空头寸也不足以覆盖剩余亏损
                }
            }
        }
    }

    // 计算指定做空订单平仓时所需的USDT数量
    function getUsdtNeededForClose(uint256 orderId) public view returns (uint256 usdtNeeded) {
        require(orderId < nextSellOrderId, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.isActive, "Order is not active");

        // 调用函数获取流动性池储备
        (uint reserveUSDT, uint reserveToken) = getReserves();

        // 计算需要购买回的代币数量，考虑了一定的滑点（这里使用买卖各5%的滑点）
        uint256 tokensToBuyBack = order.tokenAmount.mul(110).div(100);

        // 考虑滑点后的USDT成本
        usdtNeeded = reserveUSDT * tokensToBuyBack / (reserveToken - tokensToBuyBack);
        return usdtNeeded;
    }

    // 平仓指定的做空订单
    function closeShortPosition(uint256 orderId, uint256 usdtToSpend, uint256 minTokensToReceive) public nonReentrant {
        require(orderId < nextSellOrderId, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.isActive, "Order is not active or already closed");
        require(block.timestamp <= order.closeTime, "The order has expired and cannot be closed now");
        require(order.user == msg.sender, "You are not the owner of this order");

        // 计算累计利息
        uint256 interest = calculateInterest(orderId);
        require(order.margin >= interest, "Not enough margin to cover the interest");
        order.margin = order.margin.sub(interest); // 从保证金中扣除利息

        // 获取关闭时需要的USDT数量
        uint256 usdtNeeded = getUsdtNeededForClose(orderId);

        // 确保提供的usdtToSpend与计算的usdtNeeded在合理范围内
        require(usdtToSpend >= usdtNeeded.mul(95).div(100) && usdtToSpend <= usdtNeeded.mul(105).div(100), "usdtToSpend not within 5% of the required amount");

        // 确保usdtToSpend不超过两倍的头寸加上保证金
        uint256 maxUsdtToSpend = order.usdtShorted.mul(2).add(order.margin);
        require(usdtToSpend <= maxUsdtToSpend, "usdtToSpend exceeds two times the shorted USDT plus margin");
        
        // 确保合约有足够的USDT来购买回代币
        require(IERC20(USDT).balanceOf(address(this)) >= usdtNeeded, "Contract does not have enough USDT to buy back the tokens");

        // 授权 PancakeSwap 路由器合约使用合约的USDT
        IERC20(USDT).approve(address(pancakeSwapRouter), usdtNeeded);

        // 从 PancakeSwap 购买代币
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = token;
        pancakeSwapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtNeeded,
            minTokensToReceive,
            path,
            address(this),
            block.timestamp + 300
        );

        // 计算盈亏并更新保证金
        if (usdtNeeded <= order.usdtShorted) {
            uint256 profit = order.usdtShorted.sub(usdtNeeded);
            uint256 totalReturn = order.usdtShorted.add(profit).add(order.margin); // 合并做空头寸退款、盈利和剩余保证金
            IERC20(USDT).transfer(order.user, totalReturn);
        } else {
            uint256 deficit = usdtNeeded.sub(order.usdtShorted); // 计算亏损额
            if (order.margin >= deficit) {
                // 如果保证金足以覆盖亏损
                order.margin = order.margin.sub(deficit); // 从保证金中扣除亏损
                IERC20(USDT).transfer(order.user, order.usdtShorted.add(order.margin)); // 返回用户剩余的保证金加上做空头寸的资金
            } else {
                // 如果保证金不足以覆盖亏损
                uint256 remainingShortPosition = deficit.sub(order.margin); // 计算还需从做空头寸中扣除多少
                if (remainingShortPosition < order.usdtShorted) {
                    // 做空头寸足以覆盖剩余亏损
                    uint256 remainingFunds = order.usdtShorted.sub(remainingShortPosition);
                    IERC20(USDT).transfer(order.user, remainingFunds); // 将剩余的做空头寸资金返回给用户
                } else {
                    // 保证金和做空头寸合起来仍然不足以覆盖亏损
                    revert("Not enough funds to cover the deficit");
                }
            }
        }

        // 更新订单状态
        order.isActive = false;
        emit BuyOrderPlaced(orderId, msg.sender, usdtNeeded, minTokensToReceive);

        // 从用户的做空订单数组中移除该订单
        removeOrderIdForUser(msg.sender, orderId);
        delete activeOrders[orderId]; // 从活跃订单中移除
    }

    // 用户为指定做空订单增加保证金
    function addMargin(uint256 orderId, uint256 additionalMargin) public nonReentrant {
        require(orderId < nextSellOrderId, "Invalid order ID");
        SellOrder storage order = sellOrders[orderId];
        require(order.isActive, "Order is not active");
        require(order.user == msg.sender, "You are not the owner of this order");
        require(block.timestamp <= order.closeTime, "The order has already expired");

        // 从用户账户转移额外的保证金到合约
        require(IERC20(USDT).transferFrom(msg.sender, address(this), additionalMargin), "USDT transfer failed");

        // 更新订单的保证金
        uint256 newTotalMargin = order.margin.add(additionalMargin);
        order.margin = newTotalMargin;

        // 根据总保证金重新计算到期时间
        uint256 additionalSeconds = newTotalMargin.mul(1e10).div(order.usdtShorted.mul(INTEREST_PER_USDT_PER_SECOND));
        uint256 newCloseTime = order.openTime.add(additionalSeconds);

        // 调整到期时间
        order.closeTime = newCloseTime;

        emit MarginAdded(orderId, msg.sender, additionalMargin, order.closeTime);
    }

    // 更新过期但未关闭的订单的统计数据
    function updateExpiredOrders() public {
        uint256 total = 0;
        uint256 processedCount = 0;
        for (uint256 orderId = lastProcessedOrderId; orderId < nextSellOrderId && processedCount < batchSize; orderId++) {
            if (activeOrders[orderId] && sellOrders[orderId].closeTime < block.timestamp) {
                uint256 totalPosition = sellOrders[orderId].usdtShorted;
                uint256 additionalFunds = totalPosition.mul(80).div(100); // 计算0.8倍的额外头寸
                total += totalPosition + additionalFunds;
                
                delete activeOrders[orderId]; // 删除已处理的订单
                processedCount++;
            }
        }
        lastProcessedOrderId += processedCount; // 更新游标
        expiredNotClosedUSDT = total; // 更新统计变量

        // 检查是否需要重置游标
        if (lastProcessedOrderId >= nextSellOrderId) {
            lastProcessedOrderId = 0; // 重置游标到开始
        }
    }

    //公共调用结算平仓
    function settleExpiredPositions(uint256 minTokensToReceive) public nonReentrant {
        require(expiredNotClosedUSDT > 0, "No funds to settle positions");

        uint256 usdtAvailable = IERC20(USDT).balanceOf(address(this));
        require(usdtAvailable >= expiredNotClosedUSDT, "Insufficient USDT available");

        // 定义PancakeSwap交易路径
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = token;

        // 执行代币购买
        IERC20(USDT).approve(address(pancakeSwapRouter), expiredNotClosedUSDT);
        pancakeSwapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            expiredNotClosedUSDT,
            minTokensToReceive, // 可以设置为最低接受代币数量，或由前端传入
            path,
            address(this),
            block.timestamp + 300 // 5分钟的交易窗口
        );
        
        // 重置统计变量
        expiredNotClosedUSDT = 0; // 重置已处理的USDT计数器
    }

    //质押挖矿
    function stake(uint256 _stakeAmt) public nonReentrant {
        require(_stakeAmt > 0, "Staked amount needs to be greater than 0");
        require(IERC20(token).balanceOf(msg.sender) >= _stakeAmt, "Insufficient balance to stake");

        record storage thisRecord = informationAboutStakeScheme[msg.sender];
        if (thisRecord.stakeAmt == 0) {
            informationAboutStakeScheme[msg.sender] = record(
                block.timestamp,
                _stakeAmt,
                block.timestamp,
                uint256(0),
                uint256(0)
            );
            addressStore[numberOfAddressesCurrentlyStaked] = msg.sender;
            numberOfAddressesCurrentlyStaked  = (numberOfAddressesCurrentlyStaked + uint256(1));
        } else {
            uint256 newAccumulatedInterest = thisRecord.accumulatedInterestToUpdateTime.add(
                thisRecord.stakeAmt.mul(block.timestamp.sub(thisRecord.lastUpdateTime)).mul(dailyInterestRate).mul(1e18).div(8640000000000000000000000000000)
            );
            thisRecord.stakeAmt = thisRecord.stakeAmt.add(_stakeAmt);
            thisRecord.lastUpdateTime = block.timestamp;
            thisRecord.accumulatedInterestToUpdateTime = newAccumulatedInterest;
        }
        require(IERC20(token).transferFrom(msg.sender, address(this), _stakeAmt), "Token transfer failed");
        emit Staked(msg.sender);
    }

    //解除质押
    function unstake(uint256 _unstakeAmt) public nonReentrant {
        require(_unstakeAmt > 0, "Unstake amount must be greater than zero");
        record storage thisRecord = informationAboutStakeScheme[msg.sender];
        require(_unstakeAmt <= thisRecord.stakeAmt, "Withdrawing more than staked amount");
        //require(block.timestamp >= thisRecord.stakeTime + 1 hours, "Stake must be held for at least 1 hour");  // 确保至少过了1小时

        uint256 interestAccrued = thisRecord.stakeAmt
            .mul(block.timestamp - thisRecord.lastUpdateTime)
            .mul(dailyInterestRate)
            .mul(1e18)
            .div(8640000000000000000000000000000);
        uint256 newAccum = thisRecord.accumulatedInterestToUpdateTime.add(interestAccrued);
        uint256 interestToRemove = newAccum.mul(_unstakeAmt).div(thisRecord.stakeAmt);
        if ((_unstakeAmt == thisRecord.stakeAmt)){
			for (uint i0 = 0; i0 < numberOfAddressesCurrentlyStaked; i0++){
				if ((addressStore[i0] == msg.sender)){
					addressStore[i0]  = addressStore[(numberOfAddressesCurrentlyStaked - uint256(1))];
					numberOfAddressesCurrentlyStaked  = (numberOfAddressesCurrentlyStaked - uint256(1));
					break;
				}
			}
		}

        thisRecord.stakeAmt = thisRecord.stakeAmt.sub(_unstakeAmt);
        thisRecord.lastUpdateTime = block.timestamp;
        thisRecord.accumulatedInterestToUpdateTime = newAccum.sub(interestToRemove);
        thisRecord.amtWithdrawn = thisRecord.amtWithdrawn.add(interestToRemove);

        // 从合约中转出解除质押的代币数量
        require(IERC20(token).transfer(msg.sender, _unstakeAmt), "Token transfer failed");
        emit Unstaked(msg.sender);

        // 向用户支付USDT利息
        uint256 interestPayment = interestToRemove.mul(uint256(1000000) - interestTax).div(uint256(1000000));
        if (interestPayment > 0) {
            require(IERC20(USDT).balanceOf(address(this)) >= interestPayment, "Insufficient USDT in contract");
            require(IERC20(USDT).transfer(msg.sender, interestPayment), "Failed to send USDT interest payment");
            totalWithdrawals = totalWithdrawals.add(interestPayment);
        }
    }

	function updateRecordsWithLatestInterestRates() internal {
		for (uint i0 = 0; i0 < numberOfAddressesCurrentlyStaked; i0++){
			record memory thisRecord = informationAboutStakeScheme[addressStore[i0]];
			informationAboutStakeScheme[addressStore[i0]]  = record (thisRecord.stakeTime, thisRecord.stakeAmt, block.timestamp, (thisRecord.accumulatedInterestToUpdateTime + ((thisRecord.stakeAmt * (block.timestamp - thisRecord.lastUpdateTime) * dailyInterestRate * uint256(1000000000000000000)) / uint256(8640000000000000000000000000000))), thisRecord.amtWithdrawn);
		}
	}

	//计算质押利息
    function interestEarnedUpToNowBeforeTaxesAndNotYetWithdrawn(address _address) public view returns (uint256) {
		record memory thisRecord = informationAboutStakeScheme[_address];
		return (thisRecord.accumulatedInterestToUpdateTime + ((thisRecord.stakeAmt * (block.timestamp - thisRecord.lastUpdateTime) * dailyInterestRate * uint256(1000000000000000000)) / uint256(8640000000000000000000000000000)));
	}

	function totalStakedAmount() public view returns (uint256) {
		uint256 total = uint256(0);
		for (uint i0 = 0; i0 < numberOfAddressesCurrentlyStaked; i0++){
			record memory thisRecord = informationAboutStakeScheme[addressStore[i0]];
			total  = (total + thisRecord.stakeAmt);
		}
		return total;
	}

	function totalAccumulatedInterest() public view returns (uint256) {
		uint256 total = uint256(0);
		for (uint i0 = 0; i0 < numberOfAddressesCurrentlyStaked; i0++){
			total  = (total + interestEarnedUpToNowBeforeTaxesAndNotYetWithdrawn(addressStore[i0]));
		}
		return total;
	}

    // 不提取本金领取收益
    function withdrawInterestWithoutUnstaking(uint256 _withdrawalAmt) public nonReentrant {
        uint256 totalInterestEarnedTillNow = interestEarnedUpToNowBeforeTaxesAndNotYetWithdrawn(msg.sender);
        require(_withdrawalAmt <= totalInterestEarnedTillNow, "Withdrawn amount must be less than withdrawable amount");

        record memory thisRecord = informationAboutStakeScheme[msg.sender];
        informationAboutStakeScheme[msg.sender] = record(
            thisRecord.stakeTime,
            thisRecord.stakeAmt,
            block.timestamp,
            totalInterestEarnedTillNow - _withdrawalAmt,
            thisRecord.amtWithdrawn + _withdrawalAmt
        );

        uint256 interestPayment = _withdrawalAmt.mul(uint256(1000000) - interestTax).div(uint256(1000000));
        require(interestPayment > 0, "No interest to withdraw");
        require(IERC20(USDT).balanceOf(address(this)) >= interestPayment, "Insufficient USDT in contract");

        // 向用户支付USDT利息
        require(IERC20(USDT).transfer(msg.sender, interestPayment), "Failed to send USDT interest payment");
        totalWithdrawals += interestPayment;

        emit InterestPaid(msg.sender, interestPayment);
    }

	//一次性领取所有收益
    function withdrawAllInterestWithoutUnstaking() external {
		withdrawInterestWithoutUnstaking(interestEarnedUpToNowBeforeTaxesAndNotYetWithdrawn(msg.sender));
	}

    function removeOrderIdForUser(address user, uint256 orderId) internal {
        uint256[] storage orderIds = ownerToOrderIds[user];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                orderIds[i] = orderIds[orderIds.length - 1]; // 将数组最后一个元素移动到要删除元素的位置
                orderIds.pop(); // 移除数组的最后一个元素，即原来要删除的元素
                break;
            }
        }
    }

    //管理员设置代币地址
    function setTokenAddress(address newTokenAddress) public onlyOwner {
        token = newTokenAddress;
    }

    // 管理员设置资金池地址
    function setPairAddress(address _pairAddress) public onlyOwner {
        pairAddress = _pairAddress;
    }

    // 提取合约中的代币
    function withdrawToken(address _token, uint256 _amount) public onlyOwner {
        require((IERC20(_token).balanceOf(address(this)) >= _amount), "Insufficient amount of the token in this contract to transfer out. Please contact the contract owner to top up the token.");
        IERC20(_token).transfer(msg.sender, _amount);
    }

    //设置利息手续费（借出）
    function changeValueOf_interestTax(uint256 _interestTax) external onlyOwner {
		require((uint256(0) < _interestTax), "Tax rate needs to be larger than 0%");
		require((uint256(1000000) > _interestTax), "Tax rate needs to be smaller than 100%");
		interestTax  = _interestTax;
	}

    //设置每日借出利率
    function modifyDailyInterestRate(uint256 _dailyInterestRate) public onlyOwner {
		require((uint256(0) < _dailyInterestRate), "Interest rate needs to be larger than 0%");
		updateRecordsWithLatestInterestRates();
		dailyInterestRate  = _dailyInterestRate;
	}

    // 设置批处理大小
    function setBatchSize(uint256 _batchSize) public onlyOwner {
        batchSize = _batchSize;
    }

}