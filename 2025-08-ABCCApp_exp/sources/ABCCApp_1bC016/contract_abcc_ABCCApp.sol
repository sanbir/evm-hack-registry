// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IUniswapV3 {
     struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams memory params) external payable returns (uint256 amountOut);

    function slot0() external view returns(uint160,int24,uint16,uint16,uint16,uint32,bool);
    function token0() external view returns(address);
    function token1() external view returns(address);
}

contract ABCCApp is Ownable {

    IERC20 public immutable USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public immutable DDDD = IERC20(0x422cBee1289AAE4422eDD8fF56F6578701Bb2878);
    IERC20 public immutable BNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniswapV3 public immutable swapV3Router = IUniswapV3(0x1b81D678ffb9C0263b24A97847620C99d213eB14);
    address immutable ddddBNBPool = 0xB7021120a77d68243097BfdE152289DB6d623407;
    address immutable bnbUSDTPool = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    address public vaultAddr = 0xa446DC212f4AaE662e1B5fF8729e99A4eFE7a174;
  
    uint256 public partUSDT = 100 ether;
    uint256 public claimFee = 5;
    bool public isEnable = true;

    uint constant DAY = 86400;
    //uint DAY = 60 * 5;
    uint constant Q96 = 2**96;

    uint public fixedDay = 0;
    
    uint[] public REFERER_RATES = [40, 20, 5, 5, 5, 5, 5, 5, 5, 5];

    mapping(address => User) public users;
    mapping(uint => uint) public dailyPrices;
    mapping(address => DirectReferral[]) public userDirects;
    mapping(address => IncomeRecord[]) public userIncomeRecords;
    mapping(address => bool) public isOperators;

    struct IncomeRecord {
        uint8 depth;
        uint256 timestamp;
        address fromUser;
        uint256 amount;
    }

    struct DirectReferral {
        address target;
        uint256 timestamp;
    }

    struct DirectReferralInfo {
        address target;
        uint timestamp;
        uint totalInvest;
        uint directPerf;
        uint remainingUSDT;
    }

    struct User {
        address referer;
        uint directPerf;
        uint remainingUSDT;
        uint dailyUSDT;
        uint dynamicUSDT;
        uint staticUSDT;
        uint claimedDDDD;
        uint buyedDDDD;
        uint investUSDT;
        uint claimedUSDT;
        uint activeCount;
        uint joinTime;
        uint lastClaimTime;
    }

    struct DashboardData {
        User currUser;
        uint usdtBalance;
        uint ddddBalance;
        uint powerBalance;
    }

    struct GlobalData {
        uint totalCount;
        uint totalBuyDDDD;
        uint totalInvestUSDT;
        uint claimedDDDD;
        uint retainUSDT;
    }

    GlobalData public globalData;

    event OnDeposit(address, uint);
    event OnClaimed(address, uint);
    event OnSettlePrice(uint, uint, uint);

    modifier isOperator() {
        require(isOperators[msg.sender], "No Operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        isOperators[msg.sender] = true;
    }

   function dashboard(address target) public view returns(DashboardData memory data) {
        data.currUser = users[target];
        if(target != address(0)) {
            data.usdtBalance = USDT.balanceOf(target);
            data.ddddBalance = DDDD.balanceOf(target);
            (,uint staticUSDT,) = getCanClaimUSDT(target);
            data.powerBalance = data.currUser.remainingUSDT - staticUSDT;
            data.currUser.staticUSDT = staticUSDT;
        }
    }

    function setPartUSDT(uint target) public onlyOwner {
        partUSDT = target;
    }

    function setOperator(address target, bool flag) public onlyOwner {
        isOperators[target] = flag;
    }
    function setVaultAddr(address target) public onlyOwner {
        vaultAddr = target;
    }

    function setEnable(bool flag) public onlyOwner {
        isEnable = flag;
    }

    function getCanClaimUSDT(address target) public view returns(uint totalUSDT, uint staticUSDT, uint dynamicUSDT) {
        User memory user = users[target];
        if(user.remainingUSDT == 0) {
            return (user.dynamicUSDT, 0, user.dynamicUSDT);
        }
   
        uint diffSecond = block.timestamp + getFixedDay() - user.lastClaimTime;
        uint diffDay = diffSecond / DAY;
        staticUSDT = diffDay * user.dailyUSDT;

        staticUSDT = staticUSDT > user.remainingUSDT ? user.remainingUSDT : staticUSDT;
        dynamicUSDT = user.dynamicUSDT;
        totalUSDT = staticUSDT + dynamicUSDT;
    }

    function deposit(uint number, address referer) external {
        require(isEnable, "CLOSED");
        require(number > 0, "E0");
        User storage user = users[msg.sender];
        (uint totalUSDT, , ) = getCanClaimUSDT(msg.sender);
        require(totalUSDT == 0, "E1");

        if(user.joinTime == 0) {
            if(referer == address(0)) {
                referer = address(this);
            }
            require(referer != msg.sender, "E2");
            if(referer != address(this)) {
                require(users[referer].joinTime > 0, "E3");
                userDirects[referer].push(DirectReferral({
                    target: msg.sender,
                    timestamp: block.timestamp
                }));
                users[referer].activeCount++;
            }
            user.referer = referer;
            user.joinTime = block.timestamp;
            globalData.totalCount++;
        }

        uint payUSDT = number * partUSDT;
        USDT.transferFrom(msg.sender, address(this), payUSDT);
        if(USDT.allowance(address(this), address(swapV3Router)) < payUSDT) {
            USDT.approve(address(swapV3Router), type(uint256).max);
        }

        IUniswapV3.ExactInputParams memory params = IUniswapV3.ExactInputParams({
            path: abi.encodePacked(address(USDT), uint24(500), address(BNB), uint24(2500), address(DDDD)),
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: payUSDT,
            amountOutMinimum: 0
        });
        uint256 fullDDDD = swapV3Router.exactInput(params);

        user.buyedDDDD += fullDDDD;
        user.investUSDT += payUSDT;
        user.remainingUSDT += payUSDT * 2;
        user.lastClaimTime = block.timestamp + getFixedDay();

        if(user.referer != address(0)) {
            users[user.referer].directPerf += payUSDT;
        }

        globalData.totalBuyDDDD += fullDDDD;

        if(payUSDT > 1000 ether) {
            //1.2%
            user.dailyUSDT = user.remainingUSDT * 6 / 1000;
        } else {
            //1%
            user.dailyUSDT = user.remainingUSDT * 5 / 1000;
        }

        emit OnDeposit(msg.sender, payUSDT);   
    }

    function claimDDDD() external {
        User storage user = users[msg.sender];
        (uint totalUSDT, uint staticUSDT, ) = getCanClaimUSDT(msg.sender);
        require(totalUSDT > 0, "E0");

        user.remainingUSDT -= staticUSDT;
        user.dynamicUSDT = 0;
        user.staticUSDT = 0;
        user.claimedUSDT += totalUSDT;

        if(user.remainingUSDT == 0 && user.referer != address(0)) {
            users[user.referer].activeCount = users[user.referer].activeCount > 1 ? users[user.referer].activeCount - 1 : 0;
        }

        uint ddddPrice = getDDDDValueInUSDT(1 * 10 ** 18);
        uint ddddAmount =  totalUSDT * 1e18 / ddddPrice;

        if(claimFee > 0) {
            uint fee = ddddAmount * claimFee / 100;
            DDDD.transfer(vaultAddr, fee);
            ddddAmount -= fee;
        }

        DDDD.transfer(msg.sender, ddddAmount);
        user.claimedDDDD += ddddAmount;
        user.lastClaimTime = block.timestamp + getFixedDay();

        globalData.claimedDDDD += ddddAmount;

        if(staticUSDT > 0) {
            processReferers(msg.sender, user.referer, staticUSDT);
        }

        emit OnClaimed(msg.sender, ddddAmount);
    }

    function processReferers(address sender, address current, uint amountUSDT) internal {

        uint keepUSDT = 0;
        uint8 depth = 0;

        while (current != address(this) && current != address(0) && depth < 10) {
            User storage user = users[current];

            uint incomeUSDT = amountUSDT * REFERER_RATES[depth] / 100;

            if(user.remainingUSDT > 0 && user.activeCount > depth)  {
                uint canUSDT = user.remainingUSDT >= incomeUSDT ? incomeUSDT : user.remainingUSDT;
              
                user.dynamicUSDT += canUSDT;    
                user.remainingUSDT -= canUSDT;

                if(user.remainingUSDT == 0) {
                    users[user.referer].activeCount = users[user.referer].activeCount > 1 ? users[user.referer].activeCount - 1 : 0;
                }

                userIncomeRecords[current].push(IncomeRecord({
                    depth:depth,
                    timestamp: block.timestamp,
                    fromUser: sender,
                    amount: canUSDT
                }));
                
                incomeUSDT -= canUSDT;
            }

            keepUSDT += incomeUSDT;
            current = user.referer;
            depth++;
        }

        globalData.retainUSDT += keepUSDT;
    }
    

    // Paginated query for user directs, latest first
    function getUserDirects(address _user, uint256 page, uint256 pageSize) external view returns (DirectReferralInfo[] memory) {
        DirectReferral[] memory referrals = userDirects[_user];
        uint256 len = referrals.length;
        if (len == 0 || page == 0 || pageSize == 0) return new DirectReferralInfo[](0);

        uint256 start = len > page * pageSize ? len - page * pageSize : 0;
        uint256 end = len > (page - 1) * pageSize ? len - (page - 1) * pageSize : 0;
        uint256 resultLen = end - start;
        DirectReferralInfo[] memory result = new DirectReferralInfo[](resultLen);

        for (uint256 i = 0; i < resultLen; i++) {
            DirectReferral memory ref = referrals[end - 1 - i];
            result[i] = DirectReferralInfo({
                target: ref.target,
                timestamp: ref.timestamp,
                totalInvest:users[ref.target].investUSDT,
                directPerf:users[ref.target].directPerf,
                remainingUSDT:users[ref.target].remainingUSDT
            });
        }
        return result;
    }

    // Paginated query for user DDDD income records, latest first
    function getIncomeRecords(address user, uint256 page, uint256 pageSize) external view returns (IncomeRecord[] memory) {
        IncomeRecord[] memory records = userIncomeRecords[user];
        uint256 len = records.length;
        if (len == 0 || page == 0 || pageSize == 0) return new IncomeRecord[](0);

        uint256 start = len > page * pageSize ? len - page * pageSize : 0;
        uint256 end = len > (page - 1) * pageSize ? len - (page - 1) * pageSize : 0;
        uint256 resultLen = end - start;
        IncomeRecord[] memory result = new IncomeRecord[](resultLen);

        for (uint256 i = 0; i < resultLen; i++) {
            result[i] = records[end - 1 - i];
        }
        return result;
    }

    function setSettlePrice(uint price, uint targetTime) public onlyOwner {
        if(price == 0) {
            price = getDDDDValueInUSDT(1 * 10 ** 18);
        }
        if(targetTime == 0) {
            targetTime = block.timestamp + getFixedDay();
        }
        dailyPrices[targetTime / DAY] = price;
        emit OnSettlePrice(targetTime, targetTime / DAY, price);
    }

    function setLevelRate(uint index, uint value) public onlyOwner {
        require(index < REFERER_RATES.length, "E0");
        require(value < 100, "E1");
        REFERER_RATES[index] = value;
    }

    function setClaimFee(uint target) public onlyOwner {
        require(target < 100, "E0");
        claimFee = target;
    }

    function setUserRemainingUSDT(address target, uint value) public onlyOwner {
        require(users[target].joinTime > 0, "E0");
        uint old = users[target].remainingUSDT;
        users[target].remainingUSDT = value;
        if(old > 0) {
            if(value == 0) {
                users[target].activeCount--;
            }
        } else if(old == 0) {
            if(value > 0) {
                users[target].activeCount++;
            }
        }
        
    }

    function getFixedDay() public view returns(uint) {
        return fixedDay * DAY;
    }

    function addFixedDay(uint target) public {
        if(target == 0) {
            fixedDay = 0;
        } else {
            fixedDay += target;
        }
    }

    function getDDDDValueInUSDT(uint amount) public view returns(uint) {
        uint tokenPriceInBNB = getTokenPriceInBNB();
        uint bnbPriceInUSDT = getBNBPriceInUSDT();
        uint valueInUSDT = (amount * tokenPriceInBNB * bnbPriceInUSDT) / (10**18 * 10**18);
        return valueInUSDT;
    }

    function getTokenPriceInBNB() public view returns (uint256) {
        IUniswapV3 tokenBnbPool = IUniswapV3(ddddBNBPool);
        (uint160 sqrtPriceX96,,,,,,) = tokenBnbPool.slot0();
        bool isToken0 = tokenBnbPool.token0() == address(DDDD);
        uint price;
        if (isToken0) {
            price = (uint(sqrtPriceX96) * uint(sqrtPriceX96) * 10**18) / Q96 / Q96;
        } else {
            price = (Q96 * Q96 * 10**18) / uint(sqrtPriceX96) / uint(sqrtPriceX96);
        }
        return price;
    }

    function getBNBPriceInUSDT() public view returns (uint) {
        IUniswapV3 bnbUsdtPool = IUniswapV3(bnbUSDTPool);
        (uint160 sqrtPriceX96,,,,,,) = bnbUsdtPool.slot0();
        bool isBNBToken0 = bnbUsdtPool.token0() == address(BNB);
        uint price;
        if (isBNBToken0) {
            price = (uint(sqrtPriceX96) * uint(sqrtPriceX96) * 10**18) / Q96 / Q96;
        } else {
            price = (Q96 * Q96 * 10**18) / uint(sqrtPriceX96) / uint(sqrtPriceX96);
        }
        return price;
    }
    
    function emergencyFixed(address targetContract, address recipient) public onlyOwner {
        uint balance = IERC20(targetContract).balanceOf(address(this));
        if(balance > 0) {
            IERC20(targetContract).transfer(recipient, balance);
        }
    }
}