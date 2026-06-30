// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts@5.5.0/access/Ownable.sol";
import "@openzeppelin/contracts@5.5.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract JUDAOToken is ERC20, Ownable,ReentrancyGuard {
    struct UserInfo {
        address inviter;            
        uint256 id;
        uint256 tOwnedU;            
        uint256 lpAmount;           
        uint256 bnbAmount;         
        uint256 power;              
        uint256 lastReleaseDay;    
        uint256 teamBNBAmount;      
        uint256 hasTeamReward;      
        uint256 rewardDebt;
        uint256 rewardTotalAmount; 
        uint256 sellRewardAmount; 

    }

    struct DayReserves{
        uint256 usdtAmount;
        uint256 thisAmount;
        uint256 day;
    }

    modifier swapping{
        inSwap=true;
        _;
        inSwap=false;
    }

    uint256 accERC20PerPower;
    uint256 totalPower;       

    uint256 public startTime;
    uint256 public lastMiningDay;
    bool public launched;

    mapping(uint256 id=>address) public idToAddress;
    mapping(address=>UserInfo) public userInfo;
    mapping(address=>bool) public isWL;     
    mapping(uint256 day=>uint256 totalAmount) public totalAmountOfDay;
    DayReserves public lastDayReserves;
    uint256 public dailyLimit;
    
    bool inSwap;
    bool locked;
    IFundPool  IDOFundPool;

    uint256 _nextId;
    uint256 _nextQueryId;
    
    address  labAddress;
    address  foundationAddress;
    address  marketAddress;
    address  lpHolder;
    address  botAddress;
    address  highFeeAddress;


    address constant WETHToken=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDTToken=0x55d398326f99059fF775485246999027B3197955;
    address constant feeAddress=address(0xFee);
    ISwapV2Router constant SwapV2Router=ISwapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);  
    ISwapV3Router constant SwapV3Router=ISwapV3Router(0x1b81D678ffb9C0263b24A97847620C99d213eB14);  

    AutoSwap immutable autoSwap=new AutoSwap();
    
    address immutable public basePair;
    address immutable public TOP_USER;

    
    uint256 public ETH_MIN_LIMIT=(0.1 ether)-1; 
    uint256 public ETH_MAX_LIMIT=(0.1 ether)+1;     
    uint256 constant ONE_DAY=1 days;    
    bool public bindStatus;    

    event Bind(uint256 newId,address from,address inviter);
    event Deposit(address user,uint256 lpAmount,uint256 power,bool isIDO);
    event MinerReward(address user,uint256 rewardAmount);
    event TeamReward(address fromUser,address user,bool isInviter, uint256 bnbAmount);
    event Query(uint256 queryId,address user,uint256 value);
    event Sync(uint256 day,uint256 usdtAmount,uint256 thisAmount);
    event Mining(uint256 day,uint256 deadAmount,uint256 miningAmount);

    receive() external payable nonReentrant{
        if(msg.sender==address(SwapV2Router)){
            return;
        }
        if(msg.value==0.0003 ether||msg.value==0.00031 ether||msg.value==0.00032 ether||msg.value==0.00033 ether||msg.value==0.00034 ether||msg.value==0.00035 ether||msg.value==0.00036 ether){
            payable(botAddress).call{value:msg.value}("");
            emit Query(_nextQueryId++,msg.sender,msg.value);
        }else{
            _deposit();
        }

    }

    fallback() external payable nonReentrant{ 
        require(bindStatus,"launch");
        require(msg.value==0.0002 ether,"err Amount");
        uint256 bindId=msgDataToUint256(msg.data);
        address inviter=idToAddress[bindId];
        require(inviter!=address(0),"not inviter id");
        UserInfo storage user=userInfo[msg.sender];
        require(user.inviter==address(0),"exsists user");
        user.inviter=inviter;
        uint256 userId = _nextId;

        user.id = userId;
        idToAddress[userId] = msg.sender;
        
        uint256 blockNum = block.number % 100 + 1;
        _nextId += blockNum;

        address(botAddress).call{value:0.0002 ether}("");
        
        emit Bind(userId,msg.sender,inviter);
    }

    function _deposit() internal {
        
        require(msg.value > ETH_MIN_LIMIT && msg.value<ETH_MAX_LIMIT, "err value");
        
        require(startTime>0 && block.timestamp>startTime ,"launch err");

        uint256 currDay=block.timestamp/ ONE_DAY;

        totalAmountOfDay[currDay]+=msg.value;
        require(totalAmountOfDay[currDay]<=dailyLimit,"daily limit");
        
        UserInfo storage user=userInfo[msg.sender];
        require(user.inviter!=address(0)," no inviter");
        
        sync(true);

        uint256 sellBnb = msg.value*7/10;
        uint256 outUSDTAmount=SwapV3Router.exactInputSingle{value:sellBnb}(ISwapV3Router.ExactInputSingleParams({
            tokenIn:WETHToken,
            tokenOut:USDTToken,
            fee:100,
            recipient:address(this),
            deadline:block.timestamp,
            amountIn:sellBnb,
            amountOutMinimum:0,
            sqrtPriceLimitX96:0
        }));


        uint256 IDOFundAmount=outUSDTAmount/7;
        IDOFundPool.fundUSDT(IDOFundAmount);

        if(user.power>0){
            uint256 rewardAmount = user.power * accERC20PerPower /1e36 - user.rewardDebt;
            if(rewardAmount>0){
                user.rewardDebt=user.power*accERC20PerPower/1e36;
                user.rewardTotalAmount += rewardAmount;
                super._update(address(this),msg.sender,rewardAmount);
                emit MinerReward(msg.sender,rewardAmount);
            }
        }

        uint256 newLP=buyAndAddLP(msg.sender,outUSDTAmount-IDOFundAmount);

        uint256 subDays=(block.timestamp-startTime)/ ONE_DAY;
        uint256 newPower=newLP*(100+subDays)/100;

        user.power+=newPower;
        user.bnbAmount+=msg.value;
        user.lpAmount+=newLP;
        user.lastReleaseDay=currDay;
        user.rewardDebt=user.power*accERC20PerPower/1e36;

        shareTeams(msg.sender,user.inviter,msg.value);
        
        totalPower+=newPower;

        uint256 bnbBal=address(this).balance;
        if(bnbBal>0){
            (bool r,)=payable(foundationAddress).call{value:bnbBal}("");
            require(r,"err pay");
        }
        emit Deposit(msg.sender,msg.value,newPower,false);
    }

    function buyAndAddLP(address to,uint256 amount) internal swapping returns(uint256){
        uint256 halfAmount=amount/2;
        address[] memory path=new address[](2);
        path[0]=USDTToken;
        path[1]=address(this);
        uint256 thisAmount=SwapV2Router.swapExactTokensForTokens(halfAmount,0, path, address(autoSwap), block.timestamp)[1];

        super._update(address(autoSwap),address(this),super.balanceOf(address(autoSwap)));

        (, uint256 erc20Amount, uint liquidity)=SwapV2Router.addLiquidity(USDTToken,address(this),halfAmount , thisAmount, 0,0, to, block.timestamp);
        if(thisAmount > erc20Amount){
            super._update(address(this),address(0xDead),thisAmount - erc20Amount);
        }
        return liquidity;
    }

    function shareTeams(address fromUser,address toUser,uint256 bnbAmount) internal {
        uint256 inviterAmount=bnbAmount/20;
        UserInfo storage inviterUser=userInfo[toUser];
        uint256 inviterMaxAmount=inviterUser.bnbAmount*5+5e17;
        if(inviterMaxAmount > inviterUser.hasTeamReward){
            inviterMaxAmount -= inviterUser.hasTeamReward;
            if(inviterAmount>inviterMaxAmount){
                inviterAmount=inviterMaxAmount;
            }
            
            if(inviterAmount>0){
                inviterUser.hasTeamReward+=inviterAmount;
                toUser.call{value:inviterAmount}("");
                emit TeamReward(fromUser,toUser,true,inviterAmount);
            }
        }
        

        uint16 totalRatio;
        
        for(uint16 i;i<300;){
            
            if(toUser==TOP_USER){
                break;
            }

            UserInfo storage user=userInfo[toUser];
            uint16 currRatio;
            if(user.teamBNBAmount>=1000 ether&&totalRatio<250){
                 currRatio=250-totalRatio;
                
            }else if(user.teamBNBAmount>=300 ether&&totalRatio<230){
                 currRatio=230-totalRatio;
            }else if(user.teamBNBAmount>=100 ether&&totalRatio<200){
                 currRatio=200-totalRatio;
            }else if(user.teamBNBAmount>=30 ether&&totalRatio<150){
                 currRatio=150-totalRatio;
            }else if(user.teamBNBAmount>=10 ether&&totalRatio<100){
                 currRatio=100-totalRatio;
            }else if(user.teamBNBAmount>=3 ether&&totalRatio<50){
                 currRatio=50;
            }

            if(currRatio>0){
                uint256 rewardAmount=bnbAmount*currRatio/1000;
                uint256 maxAmount=user.bnbAmount*5;
                if(maxAmount > user.hasTeamReward){
                    maxAmount -= user.hasTeamReward;
                    if(rewardAmount>maxAmount){
                        rewardAmount=maxAmount;
                    }
                    user.hasTeamReward+=rewardAmount;
                    totalRatio+=currRatio;
                    toUser.call{value:rewardAmount}("") ;

                    emit TeamReward(fromUser,toUser,false,rewardAmount);
                }
            }

            user.teamBNBAmount+=bnbAmount;
            
            toUser=user.inviter;

            unchecked{
                i++;
            }
        }
    }

    function pending(address fromUser) public view returns (uint256) {
        if(totalPower==0){
            return 0;
        }

        UserInfo memory user=userInfo[fromUser];
        
        return user.power * accERC20PerPower /1e36 - user.rewardDebt;
    }

    function reward(address fromUser) public{
        UserInfo storage user=userInfo[fromUser];

        if(user.power>0){
            uint256 rewardAmount=pending(fromUser);
            if(rewardAmount>0){
                user.rewardDebt=user.power*accERC20PerPower/1e36;
                user.rewardTotalAmount += rewardAmount;
                super._update(address(this),fromUser,rewardAmount);
                emit MinerReward(fromUser,rewardAmount);
            }
        }
    }


    function _update(address from,address to,uint256 amount) internal override {
        if(inSwap){
            return super._update(from,to,amount);
        }

        reward(from);
        reward(to);
        
        if(isWL[from]||isWL[to]){
            return super._update(from,to,amount);
        }

        if(from==basePair){

            (uint lp,)=_isRemoveLiquidity(amount);
            if(lp>0){
                require(tx.origin==to ,"err origin");
                UserInfo storage user=userInfo[to];
                uint256 subPower=lp*user.power/user.lpAmount;
                if(user.power>=subPower){
                    user.power-=subPower;
                    totalPower-=subPower;
                    user.lpAmount-=lp;
                    user.rewardDebt=user.power*accERC20PerPower/1e36;

                    IDOFundPool.setUserAmount(to, user.lpAmount);
                }else{
                   revert("err lp amount");
                }

                uint256 subDays=block.timestamp/ONE_DAY  - user.lastReleaseDay;

                uint256 tAmount=(subDays>30?30:subDays)*amount/100;

                super._update(from,address(0xDead),amount-tAmount);
                super._update(from,to,tAmount);

                return ;
            }else{
                if(!launched){
                    (uint usdtAmount,,)=ISwapPair(basePair).getReserves();
                    if(usdtAmount>=10000000e18){
                        launched=true;
                    }else{
                        revert("un launched");
                    }
                }
                sync(false);
                address[] memory buyPath = new address[](2);
                buyPath[0] = USDTToken;
                buyPath[1] = address(this);

                uint256 amountUBuy = SwapV2Router.getAmountsIn(amount, buyPath)[0];
                userInfo[to].tOwnedU += amountUBuy;

                uint256 feeAmount=amount * 300 / 10000;
                super._update(from,feeAddress,feeAmount);

                super._update(from,to,amount - feeAmount);
                return;
            }
            
        }

        if(to==basePair){

            sync(true);
            require(startTime>0&&block.timestamp>startTime, "launched");
            (uint256 sellFee,bool isBurnPair,uint256 tokenAmount)=getSellFee();
            if(amount*10/tokenAmount > 1){
                 revert("amount K");
            }
            if(isBurnPair){
                uint256 fundAmount = amount/2;
                super._update(basePair,address(0xDead),amount-fundAmount);
                super._update(basePair,address(this),fundAmount);
                ISwapPair(basePair).sync();
                accERC20PerPower+=fundAmount*1e36/totalPower;
            }
            
            uint256 feeAmount=amount*sellFee/100;

            address[] memory buyPath = new address[](2);
            buyPath[0] = address(this);
            buyPath[1] = USDTToken;
            
            uint256 profitFeesAmount;
            UserInfo storage user=userInfo[from];
            uint256 subRewardAmount = user.rewardTotalAmount - user.sellRewardAmount;
            if(subRewardAmount >= amount){
                user.sellRewardAmount += amount;
            }else{
                uint256 profitAmount;
                user.sellRewardAmount = user.rewardTotalAmount;
                
                if(feeAmount<subRewardAmount){
                    profitAmount = amount - subRewardAmount;
                }else{
                   profitAmount = amount - feeAmount;
                }
                uint256 amountUOut = SwapV2Router.getAmountsOut(profitAmount,buyPath)[1];
                if (user.tOwnedU >= amountUOut) {
                    unchecked {
                        user.tOwnedU -= amountUOut;
                    }
                } else if (user.tOwnedU > 0 && user.tOwnedU < amountUOut) {
                    uint256 profitU = amountUOut - user.tOwnedU;
                    address[] memory sellPath = new address[](2);
                    sellPath[0] = USDTToken;
                    sellPath[1] = address(this);
                    uint256 profitThis = SwapV2Router.getAmountsOut(profitU, sellPath)[1];
                    profitFeesAmount = profitThis/5;
                    user.tOwnedU = 0;
                } else {
                    profitFeesAmount = (profitAmount) / 5;
                    user.tOwnedU = 0;
                }
            }
            
            super._update(from, address(this), feeAmount+profitFeesAmount);

            processFee(feeAmount,profitFeesAmount,sellFee);
    
            return super._update(from,to,amount-feeAmount-profitFeesAmount);
        }

        super._update(from,to,amount);
    }


    function getSellFee() public view returns(uint256 sellFee,bool isBurnPair,uint256 tokenAmount){
            (uint usdtAmount,uint thisAmount,)=ISwapPair(basePair).getReserves();
            DayReserves memory _lastDayReserves=lastDayReserves;
            if(_lastDayReserves.usdtAmount==0){
                return (3,false,thisAmount);
            }
            tokenAmount = thisAmount;
            uint256 ratio=usdtAmount*100/_lastDayReserves.usdtAmount;

            if(ratio<90){
                sellFee= 49;
            }else if(ratio<91){
                sellFee= 40;
            }else if(ratio<92){
                sellFee =30;
            }else if(ratio<93){
                sellFee= 20;
            }else if(ratio<94){
                sellFee =10;
            }else{
                sellFee=3;
            }

            uint256 lastPrice=_lastDayReserves.usdtAmount*1e18/_lastDayReserves.thisAmount;
            uint256 currPrice=usdtAmount*1e18/thisAmount;
            uint256 riseRatio = currPrice*100/lastPrice;
        
            if(riseRatio < 105){
                isBurnPair=true;
            }
            
    }

    function processFee(uint256 sellFeesAmount,uint256 profitFeesAmount,uint256 sellFeeRatio) internal swapping{
        uint256 buyFeeAmount=super.balanceOf(feeAddress);
        super._update(feeAddress,address(this),buyFeeAmount);
        
        uint256 sellProfitFeesAmount=profitFeesAmount/2;
        uint256 totalAmount=buyFeeAmount+sellFeesAmount+sellProfitFeesAmount;

        address[] memory path=new address[](2);
        path[0]=address(this);
        path[1]=USDTToken;

        uint256[] memory amounts=SwapV2Router.swapExactTokensForTokens(totalAmount,0,path,address(autoSwap),block.timestamp);
        autoSwap.withdraw(IERC20(USDTToken), address(this), amounts[1]);

        uint256 usdtBal;
        
        if(profitFeesAmount>0){
            accERC20PerPower+=sellProfitFeesAmount*1e36/totalPower;

            usdtBal=IERC20(USDTToken).balanceOf(address(this));
            uint256 profitFeesUsdt=usdtBal*sellProfitFeesAmount/totalAmount;

            IERC20(USDTToken).transfer(marketAddress,profitFeesUsdt*3/10);
            IERC20(USDTToken).transfer(foundationAddress,profitFeesUsdt/5);
            IERC20(USDTToken).transfer(labAddress,profitFeesUsdt/2);
        }
        
        usdtBal = IERC20(USDTToken).balanceOf(address(this));
        
        uint256 buyFeesUsdt=usdtBal*buyFeeAmount/totalAmount;
        uint256 sellTotalFee =(usdtBal-buyFeesUsdt);
        uint256 shareBal;
        uint256  highFee;
        if(sellFeeRatio > 3){
            highFee = sellTotalFee * (sellFeeRatio -3)/sellFeeRatio;
            IERC20(USDTToken).transfer(highFeeAddress,highFee);
            shareBal = (sellTotalFee - highFee)/3;
        }else{
            shareBal = sellTotalFee/3;
        }
        IERC20(USDTToken).transfer(foundationAddress,shareBal);
        IERC20(USDTToken).transfer(labAddress,shareBal);

        IDOFundPool.fundUSDT(buyFeesUsdt+(sellTotalFee - shareBal - shareBal - highFee));

    }   

    function _isRemoveLiquidity(uint256 amount) internal view returns (uint256 liquidity,uint256 amount0){
        (uint256 usdtAmount, uint256 thisAmount, uint256 balanceUSDT) = _getReserves();
       
        if (balanceUSDT < usdtAmount) {
            liquidity =
                (amount * ISwapPair(basePair).totalSupply()) /
                (super.balanceOf(basePair) - amount);
            amount0=usdtAmount-balanceUSDT;
        } else {
            uint256 amountOther;
            if (usdtAmount > 0 && thisAmount > 0) {
                amountOther = (amount * usdtAmount) / (thisAmount - amount);
                require(balanceUSDT >= amountOther + usdtAmount);
            }
        }
    }
    

    function _getReserves() public view returns (uint256 usdtAmount,uint256 thisAmount,uint256 balanceUSDT){
        ( usdtAmount,  thisAmount, ) = ISwapPair(basePair).getReserves();
        balanceUSDT = IERC20(USDTToken).balanceOf(basePair);
    }


    function balanceOf(address account) public override view returns(uint256){
        return super.balanceOf(account)+ pending(account) ;
    }

    function setBindStatus(bool _bindStatus) external onlyOwner{
        bindStatus=_bindStatus;
    }

    function startup(uint256 _startTime) external onlyOwner{
        startTime=_startTime;
        uint256 _day=_startTime/ONE_DAY;
        lastMiningDay=_day;
    }

    function sync(bool isMining) public {
        
        (uint256 usdtAmount,uint256 thisAmount,uint256 time)=ISwapPair(basePair).getReserves();
        if(usdtAmount > 0){
            DayReserves memory _lastDayReserves = lastDayReserves;
            uint256 day = time/ONE_DAY;
            if(_lastDayReserves.day < day){
                 lastDayReserves=DayReserves({
                    usdtAmount:usdtAmount,
                    thisAmount:thisAmount,
                    day:day
                });

                emit Sync( day, usdtAmount, thisAmount);
            }
            
    
        }
        uint256 _lastMiningDay = lastMiningDay;
        if(isMining && _lastMiningDay>0){
            if(totalPower==0){
                return;
            }
            uint256 currDays=block.timestamp/ ONE_DAY;
            if(currDays>_lastMiningDay){

                uint256 miningRate;
                if(usdtAmount>2000000e18){
                    miningRate=100;
                }else if(usdtAmount>1800000e18){
                    miningRate=90;
                }else if(usdtAmount>1600000e18){
                    miningRate=80;
                }else if(usdtAmount>1400000e18){
                    miningRate=70;
                }else if(usdtAmount>1200000e18){
                    miningRate=60;
                }else{
                    miningRate=50;
                }

                uint256 amountOut=thisAmount/50;
                uint256 miningAmount=amountOut*miningRate/200;
                
                super._update(basePair,address(this),miningAmount);
                uint256 deadAmount;
                if(thisAmount>1000000e18){
                    deadAmount=amountOut-miningAmount;
                    super._update(basePair,address(0xDead),deadAmount);
                }

                accERC20PerPower+=miningAmount*1e36/totalPower;

                lastMiningDay=currDays;
                ISwapPair(basePair).sync(); 
                emit Mining( currDays, deadAmount, miningAmount);
            }
        }
    }

    function setLimit(uint256 min_limit ,uint256 max_limit) external onlyOwner{
        ETH_MIN_LIMIT=min_limit;
        ETH_MAX_LIMIT=max_limit;
    }

    function multisetWL(address[] memory addrs,bool flag) external onlyOwner{
        for(uint i;i<addrs.length;){
            isWL[addrs[i]]=flag;
            unchecked{
                i++;
            }
        }
    }

    function info() external  view returns(uint256,uint256,uint256) {
        return (
                accERC20PerPower, 
                totalPower,      
                startTime
        );
    }

    function msgDataToUint256(bytes memory data) private pure returns (uint256) {
        require(data.length > 0 && data.length <= 78, "Invalid input length");
        uint256 result = 0;
        for (uint256 i = 0; i < data.length; i++) {
            uint8 byteValue = uint8(data[i]);
            require(byteValue >= 48 && byteValue <= 57, "Input must be a digit (0-9)");
            result = result * 10 + (byteValue - 48); 
        }
        return result;
    }

    function airdropUser(address[] memory users,uint256[] memory ids,address[] memory inviters) external  onlyOwner{
        for(uint256 i=0;i<users.length;){
            UserInfo storage user=userInfo[users[i]];
            require(idToAddress[ids[i]] ==address(0),"exsists user");
            user.inviter=inviters[i];
            user.id=ids[i];
            idToAddress[ids[i]] = users[i];
            emit Bind(ids[i],users[i],inviters[i]);
            unchecked{
                i++;
            }
        }
    }

    function airdropIDO(address[] memory users,uint256[] memory lpAmounts,uint256 totalLpAmount) external  onlyOwner{

        require(users.length==lpAmounts.length,"err len");
        
        sync(true);
        
        IERC20(basePair).transferFrom(msg.sender,address(this),totalLpAmount);

        uint256 subDaysRatio=(block.timestamp-startTime)/ ONE_DAY + 100;
        uint256 _accERC20PerPower=accERC20PerPower;
        for(uint i;i<users.length;){            
            UserInfo storage user=userInfo[users[i]];
            if(user.power>0){
                uint256 rewardAmount=user.power*_accERC20PerPower/1e36-user.rewardDebt;
                if(rewardAmount>0){
                    super._update(address(this),users[i],rewardAmount);
                    user.rewardDebt=user.power*_accERC20PerPower/1e36;
                    user.rewardTotalAmount+=rewardAmount;
                    emit MinerReward(users[i],rewardAmount);
                }
            }
            uint256 newPower=lpAmounts[i]*subDaysRatio/100;
            user.lpAmount+=lpAmounts[i];
            user.power+=newPower;
            user.rewardDebt=user.power*_accERC20PerPower/1e36;

            IERC20(basePair).transfer(users[i],lpAmounts[i]);
            IDOFundPool.initUserAmount(users[i], lpAmounts[i]);

            totalPower+=newPower;

            emit Deposit(users[i],lpAmounts[i],newPower,true);
            unchecked{
                i++;
            }
        }

        require(IERC20(basePair).balanceOf(address(this))==0,"err total lp amount");
    }

    function setFundPool(address addr) external onlyOwner{
        IDOFundPool=IFundPool(addr);
        isWL[addr]=true;
        _approve(address(this), addr, type(uint).max);
        IERC20(USDTToken).approve(addr, type(uint).max);
    }


    function setDailyLimit(uint256 limit) external onlyOwner{
        dailyLimit=limit;
    }

    function addresses() external view returns(address _labAddress,address _foundationAddress,address _marketAddress,address _lpHolder,address _botAddress,address _highFeeAddress){
        return ( labAddress,foundationAddress,marketAddress,lpHolder,botAddress,highFeeAddress);
    }

    function setAddresses(address _labAddress,address _foundationAddress,address _marketAddress,address _lpHolder,address _botAddress,address _highFeeAddress) external onlyOwner{
        labAddress=_labAddress;
        foundationAddress=_foundationAddress;
        marketAddress=_marketAddress;
        lpHolder=_lpHolder;
        botAddress=_botAddress;
        highFeeAddress=_highFeeAddress;
    }

    constructor(address _foundation,address _lab,address _market,address _lpHolder,address topUser,address firstUser,address _bot,address _highFeeAddress,address initUser)
            ERC20("T3 JUDAO", "JUDAO") Ownable(msg.sender) {
        
        require(address(this)>USDTToken,"err token");

        TOP_USER=topUser;

        foundationAddress=_foundation;
        labAddress=_lab;
        marketAddress=_market;
        lpHolder=_lpHolder;
        botAddress=_bot;
        highFeeAddress = _highFeeAddress;

        isWL[initUser]=true;
        isWL[_foundation]=true;
        isWL[_lpHolder]=true;


        UserInfo storage _topUser=userInfo[topUser];
        uint256 topId=10000000;
        _topUser.id=topId;
        idToAddress[topId]=topUser;

        emit Bind(topId,topUser,address(0));

        UserInfo storage _firstUser=userInfo[firstUser];
        uint256 _firstUserId=10000001;
        _firstUser.id=_firstUserId;
        _firstUser.inviter=topUser;

        idToAddress[_firstUserId]=firstUser;
        emit Bind(_firstUserId,firstUser,topUser);

        _nextId=11000000;
        _mint(initUser,330000000 ether);
        
         basePair=ISwapFactory(SwapV2Router.factory()).createPair(USDTToken,address(this));
        _approve(address(this), address(SwapV2Router), type(uint).max);
        IERC20(USDTToken).approve(address(SwapV2Router), type(uint).max);
    }
}

contract AutoSwap {
    function withdraw(IERC20 token,address to,uint256 amount) external {
        token.transfer(to,amount);
    }
}

interface IFundPool {
    function fundUSDT(uint256 amount) external  ;
    function fundJUDAO(uint256 amount) external  ;
    function setUserAmount(address user,uint256 lpBalance) external ;
    function initUserAmount(address user,uint256 lpAmount) external;
}

interface ISwapV2Router {
    function factory() external pure returns (address);
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
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface ISwapV3Router {
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
}

interface ISwapPair {
    function totalSupply() external view returns(uint256);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
}

interface ISwapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
