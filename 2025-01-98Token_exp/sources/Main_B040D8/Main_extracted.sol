// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SafeERC20,IERC20} from "./SafeERC20.sol";
import {Ownable} from "./Ownable.sol";

interface IPancakeRouter {
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

contract PancakeRouter {
    IPancakeRouter public constant _IPancakeRouter = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function getSwapRouterAmountsOut(address[] memory path, uint256 _amount) public view returns (uint256) {
        uint256 amountOut;
        uint256[] memory amounts = _IPancakeRouter.getAmountsOut(_amount, path);
        amountOut = amounts[1];
        return amountOut;
    }

    function swapTokensForTokens(address[] memory path, uint256 tokenAmount,uint256 tokenOutMin, address to) public {
        _IPancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            tokenOutMin, 
            path,
            to,
            block.timestamp + 60
        );
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to) public {
        _IPancakeRouter.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            block.timestamp + 60
        );
    }
}

contract Main is PancakeRouter, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public Token = IERC20(0xc0dDfD66420ccd3a337A17dD5D94eb54ab87523F);
    address public constant burnAddr = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant AMPLIFIED_BASE = 10000;
    uint256 public constant AMPLIFIED_DECIMALS = 1 * 10 ** 18;

    address public receiverAddress;
    address public firstAddress;
    mapping(address => address) public userRecommended;
    mapping(address => address[]) public directThrust;
    mapping(address => bool) public allowRecommend;


    uint256[6] public carPrices = [100e18,300e18,500e18,1000e18,3000e18,5000e18];
    mapping(address => mapping(uint256 => bool)) public userisBuyCarTypeOf;
    mapping(address => uint256) public userMaxTypeOf;

    uint256 public raceCarStartTime;
    uint256 public raceCarMaxCount = 3;
    mapping(address => mapping(uint256 => uint256)) public userRaceCarDayCount;
    uint256[4] public racePrices = [50e18,100e18,300e18,500e18];
    mapping(address => bool) public allowRaceCarWin;

    uint256[4] public GuildTypeByMaxnum = [0,360,120,30];
    uint256[4] public GuildTypeByUsdt = [0,2000e18,5000e18,10000e18];
    mapping(uint256 => uint256) public culGuildTypeByAddNum;
    mapping(address => uint256) public userGuildType;

    address public withdrawAddr;
    mapping(address => bool) public allowanceWithdrawAddr;

    /// @dev only eoa
    error OnlyEOA();

    /// @dev .
    /// @param user .
    /// @param recommended .
    error RegisterInvalid(address user, address recommended);

    event Register(address indexed account, address indexed referRecommender, uint256 time);
    event BuyCar(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event TokenSource(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event RaceCar(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event AddGuild(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event OwnerSetGuild(address indexed account, uint256 typeOf, uint256 time);
    event SetWithdrawAddr(address indexed user, uint256 time);
    event SetAllowanceWithdrawAddr(address indexed user, bool enabl, uint256 time);
    event Withdraw(address indexed withdrawAddr, address indexed user, uint256 amount, uint256 time);
    
    constructor(address initialOwner, uint256 time_) Ownable(initialOwner) {
        firstAddress = 0x4913F6884f3a30773f91b978af92e55f44d365C0;
        userRecommended[firstAddress] = address(1);
        allowRecommend[firstAddress] = true;
        USDT.approve(address(_IPancakeRouter), type(uint256).max);
        Token.approve(address(_IPancakeRouter), type(uint256).max);
        raceCarStartTime = time_;
        allowRaceCarWin[initialOwner] = true;
        allowanceWithdrawAddr[initialOwner] = true;
        allowRaceCarWin[0x5841Ea009385e26a9244CaDf4135F0E770DED869] = true;
        allowanceWithdrawAddr[0x5841Ea009385e26a9244CaDf4135F0E770DED869] = true;
        receiverAddress = 0xf4dc4E9C993A4C0170BEe1Ada5af55063ebD2830;
        withdrawAddr = 0xB5016619Fd21Ff430b169eF200a11aE2E689B4B7;
    }

    modifier onlyEOA() {
        _checkEOA();
        _;
    }

    function _checkEOA() internal view {
        if (msg.sender != tx.origin || msg.sender.code.length > 0) {
            revert OnlyEOA();
        }
    }

    function getToken() external view returns(uint256) {
        address[] memory path = new address[](2);
        path[0] =  address(Token);
        path[1] = address(USDT);
        return getSwapRouterAmountsOut(path,AMPLIFIED_DECIMALS);
    }


    function register(address recommendedAddr) external onlyEOA() {
        address user = _msgSender();
        if(userRecommended[user] != address(0) || !allowRecommend[recommendedAddr]) {
            revert RegisterInvalid(user,recommendedAddr);
        }
        userRecommended[user] = recommendedAddr;
        directThrust[recommendedAddr].push(user);

        emit Register(user, recommendedAddr, block.timestamp);
    } 

    function buyCar(uint256 typeOf) external onlyEOA() {
        address user = _msgSender();
        if(typeOf > 6 || typeOf == 0) {
            revert("typeOf");
        }
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }    
        if(userisBuyCarTypeOf[user][typeOf]) {
            revert("userisBuyCarTypeOf");
        }
        uint256 usdtAmount = carPrices[typeOf-1];
        USDT.safeTransferFrom(user,address(this),usdtAmount);
        allowRecommend[user] = true;
        userisBuyCarTypeOf[user][typeOf] = true;
        if(typeOf > userMaxTypeOf[user]) {
            userMaxTypeOf[user] = typeOf;
        }
        sendToken(user,usdtAmount,1);
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(Token);
                
        swapTokensForTokens(path,usdtAmount/2,0,burnAddr);
        USDT.safeTransfer(receiverAddress,USDT.balanceOf(address(this)));
        
        emit BuyCar(user,usdtAmount,typeOf,block.timestamp);
    }

    function raceCar(uint256 typeOf) external onlyEOA() {
        address user = _msgSender();
        if(typeOf > 5 || typeOf == 0) {
            revert("typeOf");
        } 
        if(userMaxTypeOf[user] == 0) {
            revert("userMaxTypeOf");
        }
        uint256 culDays = (block.timestamp - raceCarStartTime) / 1 days;
        userRaceCarDayCount[user][culDays] += 1;
        if(userRaceCarDayCount[user][culDays] > raceCarMaxCount) {
            revert("userRaceCarDayCount");
        }
        uint256 usdtAmount = racePrices[typeOf - 1];
        USDT.safeTransferFrom(user,receiverAddress,usdtAmount);
        
        emit RaceCar(user,usdtAmount,typeOf,block.timestamp);
    }

    function raceCarWin(address user, uint256 usdtAmount) external {
        if(!allowRaceCarWin[_msgSender()]) {
            revert("allowRaceCarWin");
        }
        sendToken(user,usdtAmount,2);
        USDT.safeTransferFrom(withdrawAddr,address(this),usdtAmount/2);
        addLiquidityUsdt(usdtAmount/2); 
    }

    function addGuild(uint256 guildType) external onlyEOA() {
        address user = _msgSender();
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }  
        if(guildType > 3 || guildType == 0 || userGuildType[user] == guildType) {
            revert("guildType");
        }
        culGuildTypeByAddNum[guildType] ++;
        if(culGuildTypeByAddNum[guildType] > GuildTypeByMaxnum[guildType]) {
            revert("culGuildTypeByAddNum");
        }
        uint256 usdtA;
        if(userGuildType[user] != 0 && userGuildType[user] < guildType) {
            culGuildTypeByAddNum[userGuildType[user]] --;
        } 
        usdtA = GuildTypeByUsdt[guildType] - GuildTypeByUsdt[userGuildType[user]];
        userGuildType[user] = guildType;

        USDT.safeTransferFrom(user,receiverAddress,usdtA);

        emit AddGuild(user,usdtA,guildType,block.timestamp);
    }


    function ownerSetGuild(address user,uint256 guildType) external {
        if(!allowRaceCarWin[_msgSender()]) {
            revert("allowRaceCarWin");
        }
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }  
        if(guildType > 3 || guildType == 0 || userGuildType[user] == guildType) {
            revert("guildType");
        }
        culGuildTypeByAddNum[guildType] ++;
        if(culGuildTypeByAddNum[guildType] > GuildTypeByMaxnum[guildType]) {
            revert("culGuildTypeByAddNum");
        }
        if(userGuildType[user] != 0 && userGuildType[user] < guildType) {
            culGuildTypeByAddNum[userGuildType[user]] --;
        } 
        userGuildType[user] = guildType;

        emit OwnerSetGuild(user,guildType,block.timestamp);
    }

    function sendToken(address user, uint256 value, uint256 sourceOf) private {
        address[] memory path = new address[](2);
        path[0] =  address(Token);
        path[1] = address(USDT);
        uint256 culPrice = getSwapRouterAmountsOut(path,AMPLIFIED_DECIMALS);
        uint256 amount = value * AMPLIFIED_DECIMALS / culPrice;
        Token.safeTransfer(user,amount);

        emit TokenSource(user,amount,sourceOf,block.timestamp);
    }

    function addLiquidityUsdt(uint256 usdtAmount) private {
        addLiquidity(address(Token),address(USDT),Token.balanceOf(address(this)),usdtAmount,0,usdtAmount,burnAddr);
    }

    function setReceiverAddress(address receiverAddress_) external onlyOwner {
        receiverAddress = receiverAddress_;
    }

    function setToken(address token_) external onlyOwner {
        Token = IERC20(token_);
        Token.approve(address(_IPancakeRouter), type(uint256).max);
    }

    function setAllowRaceCarWin(address addr_, bool enabl) external onlyOwner {
        allowRaceCarWin[addr_] = enabl;
    }

    function setWithdrawAddr(address addr) external onlyOwner {
        withdrawAddr = addr;

        emit SetWithdrawAddr(addr, block.timestamp);
    }

    function setAllowanceWithdrawAddr(address addr, bool enabl) external onlyOwner {
        allowanceWithdrawAddr[addr] = enabl;

        emit SetAllowanceWithdrawAddr(addr,enabl,block.timestamp);
    }

    function setPrice(uint256[6] memory carPrices_, uint256[4] memory racePrices_, uint256[4] memory GuildTypeByUsdt_) external onlyOwner {
        carPrices = carPrices_;
        racePrices = racePrices_;
        GuildTypeByUsdt = GuildTypeByUsdt_;
    }

    function setRaceCarMaxCount(uint256 raceCarMaxCount_) external onlyOwner {
        raceCarMaxCount = raceCarMaxCount_;
    }

    function withdraw(address addr,uint256 amount) external {
        if(allowanceWithdrawAddr[_msgSender()]) {
            USDT.safeTransferFrom(withdrawAddr,addr, amount);

            emit Withdraw(withdrawAddr,addr,amount,block.timestamp);
        }
    }

    function withdrawToken(address addr,uint256 amount, address token_) external {
        if(allowanceWithdrawAddr[_msgSender()]) {
            IERC20(token_).safeTransfer(addr, amount);

            emit Withdraw(withdrawAddr,addr,amount,block.timestamp);
        }
    }

    function addUser(address[] memory users, address[] memory recommendedAddrs) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            userRecommended[users[i]] = recommendedAddrs[i];
        }
    }

    function addUserBuyCar(address[] memory users, uint256[] memory typeOfs) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            allowRecommend[users[i]] = true;
            userisBuyCarTypeOf[users[i]][typeOfs[i]] = true;
        }
    }

    function addUserGuild(address[] memory users, uint256[] memory guildTypes) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            culGuildTypeByAddNum[guildTypes[i]] ++;
            userGuildType[users[i]] = guildTypes[i];
        }
    }
}
