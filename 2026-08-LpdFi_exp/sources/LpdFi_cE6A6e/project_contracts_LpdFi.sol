// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./library/PancakeLibrary.sol";
import "./interface/IPancakeRouter01.sol";
import "./interface/IPancakePair.sol";
import "./Binding.sol";
import "./Lpd.sol";
import "./LpdBasic.sol";

enum OrderStatus {
    None,
    Active,
    Redeemed
}

struct Order{
    uint64 startIssue;
    uint64 lastIssue;
    OrderStatus status;
    uint256 tokenAmount;
    uint256 uAmount;
    uint256 interestRate;
    uint256 interestClaimable;
    uint256 interestClaimed;
    uint256 interestTop;
}   

contract LpdFi is ReentrancyGuard, Ownable {
    using SafeERC20 for Lpd;
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;
    using Address for address;

    error NoRight();
    error AlreadyStart();
    error LenError();
    error NoBinding();
    error NoStart();
    error ExceedsMaxOrderNum();
    error NeedMultipleMinAmount();
    error BalanceNotEnough();
    error StatusError();
    error NoInterest();
    error Len0();
    error IdError();
    error ExceedsRest();
    error ExceedsMaxPerOrder();
    error AlreadyClaimedThisIssue();

    event SetStart(uint64 startTime);
    event Buy(
        address indexed account,
        uint256 indexed orderId,
        uint64 issue,
        uint256 tokenAmount,
        uint256 uAmount,
        uint256 interestTop
    );
    event CloseOrder(
        address indexed account,
        uint256 indexed orderId,
        uint256 tokenPrice,
        uint256 tokenAmount
    );
    event ClaimInterest(
        address indexed account,
        uint256 indexed orderId,
        uint64 lastIssue,
        uint64 issue,
        uint256 interestRate,
        uint256 interestClaimed,
        uint256 receivedAmount,
        uint256 feeAmount,
        uint256 newInterestRate
    );
    event DisperseDividend(
        uint64 indexed issue,
        address indexed adr,
        uint256 amount
    );
    event ClaimProfit(
        address indexed account,
        uint256 receivedamount,
        uint256 feeAmount
    );    

    uint256 public constant INTEREST_RATE = 500000;
    uint256 public constant INTEREST_TOP = 50000000;
    uint256 public constant INTEREST_REDUCED = 90000000;
    uint256 public constant BASE = 100000000;
    uint64 public constant ISSUE_PERIOD = 1 days;
    uint64 public constant STARTTIME_OFFSET = 16 hours;
    uint64 public constant MAX_ORDER_NUM = 5;
    uint256 public constant PROJECT_RATE = 200000;
    uint256 public constant OPERATION_RATE = 300000;
    uint256 public constant NFT_RATE = 300000;
    
    address private constant ROUTER_ADDRESS =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant USDC_ADDRESS =
        0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    Lpd public immutable token;
    address public immutable pair;
    Binding public immutable binding;    
    address public immutable basic;
    address public immutable project;
    address public immutable operation;
    address public immutable feeAddress;

    mapping(address=>Order[]) public orders;
    mapping(address=>uint256[]) public activeOrderIndexPerAccount;
    mapping(address => uint256) public otherInterest;
    uint64 public lastDispersedIssue;    
    uint64 public fiStartTime;
    uint256 public investedUAmount;
    mapping(address => mapping(uint64 => uint256)) public timesPerIssuePerAccount;

    constructor(
        address bindingAddress,
        address tokenAddress,      
        address _p,
        address _operation,
        address _fee,
        address m
    ) Ownable(m) {       
        token = Lpd(tokenAddress);
        pair = PancakeLibrary.pairFor(
            IPancakeRouter01(ROUTER_ADDRESS).factory(),
            tokenAddress,
            USDC_ADDRESS
        );
        binding = Binding(bindingAddress);
        basic = address(new LpdBasic(m, address(this)));
        project = _p;
        operation = _operation;
        feeAddress = _fee;
    }

    function setStart() external {
        if (msg.sender != owner()) {
            revert NoRight();
        }
        if (fiStartTime > 0) {
            revert AlreadyStart();
        }
        fiStartTime = nextDay();
        emit SetStart(fiStartTime);
    }

    function disperseDaily() public returns(uint64){
        if (fiStartTime == 0 || fiStartTime > block.timestamp) {
            revert NoStart();
        }
        uint64 issue = getIssue();
        if(issue > lastDispersedIssue){
            for(uint64 i = lastDispersedIssue + 1; i <= issue; ++i){
                uint256 projectInterest = investedUAmount * PROJECT_RATE / BASE;
                otherInterest[project] += projectInterest;
                emit DisperseDividend(i, project, projectInterest);
                uint256 operationInterest = investedUAmount * OPERATION_RATE / BASE;
                otherInterest[operation] += operationInterest;
                emit DisperseDividend(i, operation, operationInterest);
                uint256 nftInterest = investedUAmount * NFT_RATE / BASE;
                otherInterest[basic] += nftInterest;
                LpdBasic(basic).setDisperse(i, nftInterest);
                emit DisperseDividend(i, basic, nftInterest);
            }
            lastDispersedIssue = issue;
        }
        return issue;
    }

    function buy(
        uint256 uAmount
    ) external nonReentrant {
        if (binding.parents(msg.sender) == address(0)) {
            revert NoBinding();
        }       
        if (activeOrderIndexPerAccount[msg.sender].length >= MAX_ORDER_NUM){
            revert ExceedsMaxOrderNum();
        }        
        uint64 issue = disperseDaily();
        if (uAmount % 1e18 != 0) {
            revert NeedMultipleMinAmount();
        }
        uint256 tokenAmount = (uAmount * 1e18) / token.price();
        if (token.balanceOf(msg.sender) < tokenAmount) {
            revert BalanceNotEnough();
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        Order memory order= Order({
            startIssue: issue,
            lastIssue: issue,
            status: OrderStatus.Active,
            tokenAmount: tokenAmount,
            uAmount: uAmount,
            interestRate: INTEREST_RATE,
            interestClaimable: 0,
            interestClaimed: 0,
            interestTop: uAmount * INTEREST_TOP / BASE
        });
        orders[msg.sender].push(order);
        activeOrderIndexPerAccount[msg.sender].push(orders[msg.sender].length - 1);
        investedUAmount += uAmount;
        emit Buy(
            msg.sender,
            orders[msg.sender].length - 1,
            issue,
            tokenAmount,
            uAmount,
            order.interestTop
        );
    }

    function claimInterest(uint256 id) external nonReentrant{
        uint64 issue = disperseDaily();
        if(id >= orders[msg.sender].length){
            revert IdError();
        }
        Order memory order = getOrder(msg.sender, id);
        if(order.status != OrderStatus.Active){
            revert StatusError();
        }
        if(order.interestClaimable <= 0){
            revert NoInterest();
        }
        if (timesPerIssuePerAccount[msg.sender][issue] >=1){
            revert AlreadyClaimedThisIssue();
        }
        timesPerIssuePerAccount[msg.sender][issue] += 1;
        orders[msg.sender][id].interestClaimed += order.interestClaimable;
        orders[msg.sender][id].interestClaimable = 0;
        orders[msg.sender][id].lastIssue = issue;        
        if(order.interestClaimable + order.interestClaimed < order.interestTop){
            orders[msg.sender][id].interestRate = reduceInterestRate(order.interestRate);
        }
        else{
            orders[msg.sender][id].status = OrderStatus.Redeemed;
            investedUAmount -= order.uAmount;
            uint256 tokenAmount = (order.uAmount * 1e18) / token.price();
            IERC20(token).safeTransfer(msg.sender, tokenAmount);
            uint256 len = activeOrderIndexPerAccount[msg.sender].length;
            for(uint256 i =0; i < len; ++i){
                if(activeOrderIndexPerAccount[msg.sender][i] == id){
                    activeOrderIndexPerAccount[msg.sender][i] = activeOrderIndexPerAccount[msg.sender][len -1];
                    activeOrderIndexPerAccount[msg.sender].pop();
                    break;
                }
            }
            emit CloseOrder(msg.sender, id, token.price(), tokenAmount);
        }
        (,uint256 amountB) = removeLp(order.interestClaimable);
        uint256 a = (amountB * 99) / 100;
        IERC20(USDC_ADDRESS).safeTransfer(msg.sender, a);
        IERC20(USDC_ADDRESS).safeTransfer(feeAddress, amountB - a);
        emit ClaimInterest(msg.sender, id, order.lastIssue, issue, order.interestRate, order.interestClaimable, a, amountB - a, orders[msg.sender][id].interestRate);
    }

    function removeLp(uint256 usdcAmount) private returns (uint256 amountA,uint256 amountB) {
        uint256 needLpAmount;
        uint256 lpTotalSupply = IERC20(pair).totalSupply();
        (uint256 r0, uint256 r1, ) = IPancakePair(pair).getReserves();
        if (address(token) == IPancakePair(pair).token0()) {
            needLpAmount = (usdcAmount * lpTotalSupply) / r1;
        } else {
            needLpAmount = (usdcAmount * lpTotalSupply) / r0;
        }
        IERC20(pair).approve(ROUTER_ADDRESS, needLpAmount);
        (amountA,amountB) = IPancakeRouter01(ROUTER_ADDRESS).removeLiquidity(
            address(token),
            USDC_ADDRESS,
            needLpAmount,
            0,
            0,
            address(this),
            block.timestamp + 300
        );
    }

    function accountOrders(address account,uint256 pageIndex,uint256 pageSize) external view returns(Order[] memory orderList){
        uint256 len = orders[account].length;
        uint128 issue = getIssue();
        uint256 start = pageIndex * pageSize;
        if(len > start) {
            orderList = new Order[](Math.min(pageSize, len - start));
            uint256 end = Math.min(len, start + pageSize);
            for(uint256 i = start; i < end; ++i) {
                Order memory order = orders[account][i];
                if(order.status == OrderStatus.Active){
                    uint256 interest = order.interestRate * order.uAmount * (issue - order.lastIssue) / BASE;
                    if(order.interestClaimable + order.interestClaimed + interest >= order.interestTop){
                        order.interestClaimable = order.interestTop - order.interestClaimed;
                    }
                    else
                    {
                        order.interestClaimable += interest;
                    }
                } 
                orderList[i - start]= order;
            }
        }
    }    

    function activeOrderIndex(address account) external view returns(uint256[] memory){
        return activeOrderIndexPerAccount[account];
    }

    function orderLength(address account) external view returns(uint256){
        return orders[account].length;
    }

    function getOrder(address account,uint256 orderId) public view returns(Order memory){
        Order memory order = orders[account][orderId];
        uint64 issue = getIssue();
        if(order.status == OrderStatus.Active){
            uint256 interest = order.interestRate * order.uAmount * (issue - order.lastIssue) / BASE;
            if(order.interestClaimable + order.interestClaimed + interest >= order.interestTop){
                order.interestClaimable = order.interestTop - order.interestClaimed;
            }
            else
            {
                order.interestClaimable += interest;
            }
        } 
        return order;
    }   

    function claimDividend(
        uint256[] calldata basicIssues,
        uint256[] calldata basicAmounts,
        bytes32[][] calldata basicMerkleProofs
    ) external nonReentrant {
        if (
            basicIssues.length != basicAmounts.length ||
            basicIssues.length != basicMerkleProofs.length
        ) {
            revert LenError();
        }
        disperseDaily();
        for (uint256 i = 0; i < basicIssues.length; ++i) {
            LpdBasic(basic).checkMerkleRoot(
                msg.sender,
                basicIssues[i],
                basicAmounts[i],
                basicMerkleProofs[i]
            );
            if(otherInterest[basic] < basicAmounts[i]){
                revert ExceedsRest();
            }
            otherInterest[basic] -= basicAmounts[i];
            LpdBasic(basic).claim(msg.sender, basicIssues[i], basicAmounts[i]);
            (,uint256 amountB) = removeLp(basicAmounts[i]);
            uint256 a = (amountB * 99) / 100;
            IERC20(USDC_ADDRESS).safeTransfer(msg.sender, a);
            IERC20(USDC_ADDRESS).safeTransfer(feeAddress, amountB - a);
        }
    }

    function claimProfit(uint256 amount) external nonReentrant {
        if(msg.sender != project && msg.sender != operation){
            revert NoRight();
        }
        if(amount > otherInterest[msg.sender]){
            revert ExceedsRest();
        }
        disperseDaily();
        otherInterest[msg.sender] -= amount;
        (,uint256 amountB) = removeLp(amount);
        uint256 a = (amountB * 99) / 100;
        IERC20(USDC_ADDRESS).safeTransfer(msg.sender, a);
        IERC20(USDC_ADDRESS).safeTransfer(feeAddress, amountB - a);
        emit ClaimProfit(msg.sender, a, amountB - a);
    }

    function nextDay() private view returns (uint64) {
        return uint64((block.timestamp - STARTTIME_OFFSET) / ISSUE_PERIOD + 1) * ISSUE_PERIOD + STARTTIME_OFFSET;
    }

    function getIssue() public view returns(uint64){
        return uint64((block.timestamp - fiStartTime) / ISSUE_PERIOD);
    }  

    function reduceInterestRate(uint256 interestRate) private pure returns(uint256){
        return (interestRate * INTEREST_REDUCED + BASE/2) / BASE;
    }
}
