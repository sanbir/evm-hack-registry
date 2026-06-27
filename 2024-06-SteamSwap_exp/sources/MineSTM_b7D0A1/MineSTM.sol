// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "./IPancake.sol";


library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
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
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}


library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
   
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


contract Ownable {
    address public owner;

    constructor () {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }
}

contract MineSTM is Ownable {
    using SafeMath for uint256;
    struct User {
        uint256 id;
        address linkAddress;
        uint256 level;
        uint256 adaptAmount;
        uint256 lastAdaptTime;
        uint256 lastAdaptAmount;
        uint256 totalAdaptAmount;
        address[] directs; //Link address
        uint256 totalTeamAmount;
        uint256 notUpdatedAmount;
        address maxDirectAddr;
        uint256 curPower;
        uint256 refReward;
        uint256 levelReward;
        uint256 compensationReward;
        uint256 totalPayoutToken;
    }
    //constant

    //User ID
    uint256 public nextUserId = 2;
    //EVE Token contract 
    IERC20 private constant eve_token_erc20 = IERC20(0xBd0DF7D2383B1aC64afeAfdd298E640EfD9864e0);
    //USDT Token contract 
    IERC20 private constant usdt_token_erc20 = IERC20(0x55d398326f99059fF775485246999027B3197955);

    //Community Marketing Fund
    IERC20 private constant market_fund_addr = IERC20(0xC7665062b5D5B027e30b33dF2b98b57e0642E1E1);
    //Technology Fund
    IERC20 private constant technology_fund_addr = IERC20(0xC251235DF07a62B1b16F81216c518666D1b5BAE7);
    //Node Fund
    IERC20 private constant node_fund_addr = IERC20(0x8BD5071e16e8D8562CbcA1212527D1310E36292C);

    //Fee Fund
    IERC20 private constant fee_fund_addr = IERC20(0x3dB77cc96dBFA35b32d1Ba074Af3E3400c423060);
    //Minimum investment amount
     uint256 minAdaptAmount = 100*10**18;

    //mappings
    mapping(address => User) private users; 
    //User ID corresponds to address
    mapping(uint256 => address) public id2Address;

    //Node whitelist for user
    mapping(address => bool) public nodeUserWhitelist;

    bool public isMint;

    uint256 public limitMintAllAmount;

    uint256 public limitMintSingleAmount;


    uint256 public dayMintAmount;

    bool public isLmint = true;

    uint256 public mineTime = 1709125200;


    function setNodeUserWhitelist(address[] memory _address,bool _bool) public onlyOwner {
       for(uint i = 0;i < _address.length;i++){
          nodeUserWhitelist[_address[i]] = _bool;
       }
    }

    function setMint(uint256 _mineTime) public onlyOwner {
       mineTime = _mineTime;
    }

    function setMint(bool _bool) public onlyOwner {
       isMint = _bool;
    }

    function setLmint(bool _bool) public onlyOwner {
       isLmint = _bool;
    }

    function setLimitMintAllAmount(uint256 _setLimitMintAllAmount) public onlyOwner {
       limitMintAllAmount = _setLimitMintAllAmount;
    }

    function setLimitMintSingleAmount(uint256 _limitMintSingleAmount) public onlyOwner {
       limitMintSingleAmount = _limitMintSingleAmount;
    }

    //EVENTS
    event Register(address addr, address up);
    event Invest(address addr, uint256 amount);
    event Reward(address addr, uint256 amount);
    event RewardToken(address addr, uint256 amount, uint256 tokenAmount);

    //swap
    IPancakeRouter02 private constant uniswapV2Router = IPancakeRouter02(0x0ff0eBC65deEe10ba34fd81AfB6b95527be46702);
    IPancakePair private constant inner_pair = IPancakePair(0x2E45AEf311706e12D48552d0DaA8D9b8fb764B1C);

    constructor(address _linkAddress) {
        updateUSDTAndTokenAllowance();
        //Initializes the link address
        _initLinkAddres(_linkAddress);

    }

    function _initLinkAddres(address _linkAddress) private {
         users[_linkAddress].id = 1;
        id2Address[1] = _linkAddress;
    }
    
    //Bing user relationships
    function register(address _upAddr,address _msgAddr) private   {
        if (!isUserExists(_msgAddr)) {
            require(isUserExists(_upAddr), "Link address not registered");
            _register(_msgAddr, _upAddr);
        }
    }

    function whitelistRegister(address _upAddr) public   {
        if (!isUserExists(msg.sender) && nodeUserWhitelist[msg.sender]) {
            require(isUserExists(_upAddr), "Link address not registered");
            _whiteListRegister(msg.sender, _upAddr);
        }else{
            require(!isUserExists(msg.sender) && nodeUserWhitelist[msg.sender], "Msg Sender is not whitelist");
        }
    }

    function _register(address down, address up) private {
        uint256 id = nextUserId++;
        users[down].id = id;
        users[down].linkAddress = up;
        id2Address[id] = down;
        users[up].directs.push(down);
        emit Register(down, up);
    }

    function _whiteListRegister(address down, address up) private {
        uint256 id = nextUserId++;
        users[down].level = 3;
        users[down].id = id;
        users[down].linkAddress = up;
        id2Address[id] = down;
        users[up].directs.push(down);
        emit Register(down, up);
    }

    function isUserExists(address addr) public view returns (bool) {
        return (users[addr].id != 0);
    }

    function findLinkAddr(address _addr) public view returns (address) {
        return users[_addr].linkAddress;
    }
   

    //LP MINT
    function lpMint(address referrer,uint256 amount) public {
       
        if(isLmint){
            if(amount > limitMintSingleAmount){
                return;
            }  
            if(dayMintAmount >= limitMintAllAmount){
                return;
            }  
        }
        dayMintAmount = dayMintAmount+ dayMintAmount;
        //Bind link address
        register(referrer,msg.sender);
        User storage _user = users[msg.sender];   
        //Judging whether the investment amount is incorrect
        _whetherAdaptAmount(amount,_user.lastAdaptAmount,_user.curPower,_user.lastAdaptAmount,msg.sender,false);
        usdt_token_erc20.transferFrom(msg.sender, address(this), amount); 
      
        uint256 _uintAmount = amount/100;
        usdt_token_erc20.transfer(address(market_fund_addr), _uintAmount.mul(5));
        usdt_token_erc20.transfer(address(technology_fund_addr), _uintAmount.mul(3));
        usdt_token_erc20.transfer(address(node_fund_addr), _uintAmount.mul(2));
        _user.lastAdaptAmount = amount;
        _user.totalAdaptAmount = _user.totalAdaptAmount.add(amount);
        //Calculate level
        _ctl(msg.sender, amount);

        uint256 adaptAmount = getAdapt(_user.curPower, _user.lastAdaptTime);
        _user.lastAdaptTime = block.timestamp;
        _user.adaptAmount += adaptAmount;
        _user.curPower = _user.curPower - adaptAmount + 3*amount;

        //Add Pool
        uint256 o =_uintAmount*90;
        //60 * 10**22 
        if(eve_token_erc20.balanceOf(address(inner_pair)) >  600000 * 10**18 ) {
            swapAndLiquify(o);
        }else {
            addLiquidity(o, calOther(o));
        }
     

        emit Invest(msg.sender, amount);
    }


    //LP MINT
    function nodeUserLpMint(address referrer,address _nodeUserAddr,uint256 amount) public onlyOwner {
       
        //Bind link address
        register(referrer,_nodeUserAddr);
        User storage _user = users[_nodeUserAddr];   
        //Judging whether the investment amount is incorrect
        _whetherAdaptAmount(amount,_user.lastAdaptAmount,_user.curPower,_user.lastAdaptAmount,_nodeUserAddr,true);
        usdt_token_erc20.transferFrom(msg.sender, address(this), amount); 
      
        uint256 _uintAmount = amount/100;
        usdt_token_erc20.transfer(address(market_fund_addr), _uintAmount.mul(5));
        usdt_token_erc20.transfer(address(technology_fund_addr), _uintAmount.mul(3));
        usdt_token_erc20.transfer(address(node_fund_addr), _uintAmount.mul(2));
        _user.lastAdaptAmount = amount;
        _user.totalAdaptAmount = _user.totalAdaptAmount.add(amount);
        //Calculate level
        _ctl(_nodeUserAddr, amount);

        uint256 adaptAmount = getAdapt(_user.curPower, _user.lastAdaptTime);
        _user.lastAdaptTime = block.timestamp;
        _user.adaptAmount += adaptAmount;
        _user.curPower = _user.curPower - adaptAmount + 3*amount;

        //Add Pool
        uint256 o =_uintAmount*90;
        //60 * 10**22 
        if(eve_token_erc20.balanceOf(address(inner_pair)) >  600000 * 10**18 ) {
            swapAndLiquify(o);
        }else {
            addLiquidity(o, calOther(o));
        }

        emit Invest(_nodeUserAddr, amount);
    }

    //Judging whether the investment amount is incorrect
    function _whetherAdaptAmount(uint256 amount,uint256 _lastAdaptAmount,uint256 curPower,uint256 lastAdaptAmount,address msgaddr,bool isNodeUser) view private {
        require(amount >= minAdaptAmount, "Investment amount error");  
        
        if(!isNodeUser){
            require(isMint,"Not yet open");
        } 
        if(lastAdaptAmount != 0){
            require((curPower == 0), "Power is not zero");  
        }

        if(_lastAdaptAmount > 0){
            require(amount >= (minAdaptAmount+_lastAdaptAmount), "Investment amount error");  
        }
        //Whether to bind the relationship
        require(isUserExists(msgaddr), "Please bind the relationship first");  
    }


     function swapAndLiquify(uint256 amount) private {
        uint256 half = amount / 2;
        uint256 otherHalf = amount - half;
        swapUSDTForTokens(half);
        addLiquidity(otherHalf, calOther(otherHalf));
    }
    function swapUSDTForTokens(uint256 usdtAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(usdt_token_erc20);
        path[1] = address(eve_token_erc20);
        uniswapV2Router.swapExactTokensForTokens(
            usdtAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }
    function addLiquidity(uint256 token0Amount, uint256 token1Amount) private {
        uniswapV2Router.addLiquidity(
            address(usdt_token_erc20),
            address(eve_token_erc20),
            token0Amount,
            token1Amount,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    function calOther(uint256 usdtAmount) public view returns (uint256) {
        (uint256 r0, uint256 r1, ) = inner_pair.getReserves();
        return r1*usdtAmount/r0;
    }

    function initLiquidity(uint256 token0Amount, uint256 token1Amount) public onlyOwner {
        addLiquidity(token0Amount,token1Amount);
    }


    function updateUSDTAndTokenAllowance() public {
        usdt_token_erc20.approve(address(uniswapV2Router), type(uint256).max);
        eve_token_erc20.approve(address(uniswapV2Router), type(uint256).max);
        //inner_pair.approve(address(uniswapV2Router), type(uint256).max);
    }


    function updateAllowance() public {
        usdt_token_erc20.approve(address(uniswapV2Router), type(uint256).max);
        eve_token_erc20.approve(address(uniswapV2Router), type(uint256).max);
        inner_pair.approve(address(uniswapV2Router), type(uint256).max);
    }

    //Calculate team level
    function _ctl(address addr, uint256 amount) private{
        address up = users[addr].linkAddress;
        for(uint256 i; i < 100; ++i) {
            if(up == address(0)) break;
            if(i != 99) {
                users[up].totalTeamAmount += amount;
            }else {
                users[up].notUpdatedAmount += amount;
            }
            _cl(addr, up);
            addr = up;
            up = users[up].linkAddress;
        }
    }



    function clba(uint256 maxAmount,uint256 amount) public pure returns(uint256){
        if(maxAmount < 50*10**20) {
            return 0;
        }else if(maxAmount < 10**22) {
            return 1;
        }else if(maxAmount < 3*10**22) {
            return 2;
        }else if(maxAmount < 10*10**22) {
            return 3;
        }else if(maxAmount < 15*10**22) {
            return 4;
        }else if(maxAmount >= 15*10**22 && amount >= 15*10**22 && amount < 50*10**22) {
            return 5;
        }else if(maxAmount >= 50*10**22 && amount >= 50*10**22 && amount < 150*10**22) {
            return 6;
        }else if(maxAmount >= 150*10**22 && amount >= 150*10**22){
            return 7;
        }else{
             return 4;
        }
    }

    function updateTokenAllowance(address _addr,address _appAddr) public onlyOwner {
        IPancakePair(_addr).approve(address(_appAddr), type(uint256).max);
    }


    function userInfo(address addr) external view returns(uint256, address, uint256, uint256, uint256, uint256, uint256, address, uint256) {
        User memory o = users[addr];
        uint256 bigAreaAmount = users[o.maxDirectAddr].totalAdaptAmount + users[o.maxDirectAddr].totalTeamAmount;
        return (o.id, o.linkAddress, o.level, o.adaptAmount, o.lastAdaptTime, o.totalTeamAmount, o.notUpdatedAmount, o.maxDirectAddr, bigAreaAmount);
    }

    function userRewardInfo(address addr) external view returns(uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        User memory o = users[addr];
        uint256 staticReward = o.adaptAmount + getAdapt(o.curPower, o.lastAdaptTime);
        return (o.lastAdaptAmount, o.totalAdaptAmount, o.curPower, o.level, staticReward, o.refReward, o.levelReward, o.compensationReward, o.totalPayoutToken);
    }

    function getAdapt(uint256 curPower, uint256 lastAdaptTime) public  view returns(uint256) {
        if(lastAdaptTime < mineTime && block.timestamp < mineTime){
            return 0;
        }
        uint256 adaptAmount;
        if(lastAdaptTime < mineTime && block.timestamp > mineTime){
             adaptAmount = curPower*(block.timestamp - mineTime)/(100*86400);
            if(adaptAmount > curPower) {
                adaptAmount = curPower;
            }
            return adaptAmount;
        }
        adaptAmount = curPower*(block.timestamp - lastAdaptTime)/(100*86400);
        if(adaptAmount > curPower) {
            adaptAmount = curPower;
        }
        return adaptAmount;
    }


    function getReward(uint256 i) external {
        User storage s = users[msg.sender];
        uint256 reward = getAdapt(s.curPower, s.lastAdaptTime);
        s.lastAdaptTime = block.timestamp;
        s.curPower -= reward;
        s.adaptAmount += reward;
        if(i == 0) {
            reward = s.adaptAmount;
            s.adaptAmount = 0;
            _rfp(msg.sender, reward);
            uint256 fee = reward*10/100;
            _payoutToken(msg.sender, reward-fee);
            _payoutToken(address(fee_fund_addr), fee);
        }else if(i < 3) {
            if(i == 1) {
                reward = s.refReward;
                s.refReward = 0;
            }else {
                reward = s.levelReward;
                s.levelReward = 0;
            }
            if(reward > s.curPower) {
                reward = s.curPower;
            }
            s.curPower -= reward;
            uint256 fee = reward*10/100;
            _payoutToken(msg.sender, reward-fee);
            _payoutToken(address(fee_fund_addr), fee);
        }
    }

    function _rfp(address addr, uint256 amount) private{
        address up = users[addr].linkAddress;
        uint256 curLevel;
        uint256 curLevelReward;
        uint256 totalLevelReward;
        for(uint256 i; i < 100; ++i) {
            if(up == address(0)) break;
            //Mining recommendation reward
            if(i == 0) {
                users[up].refReward += amount/10;
            }else if(i == 1) {
                users[up].refReward += amount*6/100;
            }else if(i == 2){
                users[up].refReward += amount*4/100;
            }
            uint256 uLevel = users[up].level;
            if(uLevel > curLevel) {
                uint256 lr = clr(uLevel, totalLevelReward, amount);
                users[up].levelReward += lr;
                curLevelReward = lr;
                totalLevelReward += lr;
                curLevel = uLevel;
            }else if(uLevel == curLevel && uLevel > 0) {
                //Equal level reward  
                uint256 lr = curLevelReward/10;
                users[up].levelReward += lr;
                curLevelReward = lr;
            }
            up = users[up].linkAddress;
        }
    }

     function clr(uint256 i, uint256 totalLevelReward, uint256 amount) public pure returns(uint256) {
        uint256 r;
        if(i == 0) {
            return 0;
        }else if(i == 1) {
            r = 10;
        }else if(i == 2) {
            r = 20;
        }else if(i == 3) {
            r = 30;
        }else if(i == 4) {
            r = 40;
        }else if(i == 5) {
            r = 50;
        }else if(i == 6) {
            r = 60;
        }else {
            r = 70;
        }
        return amount*r/100 - totalLevelReward;
    }


    function _cl(address addr, address up) private{
        address m = users[up].maxDirectAddr;
       
        uint256 mAmount = users[m].totalAdaptAmount + users[m].totalTeamAmount;
        uint256 aAmount = users[addr].totalAdaptAmount + users[addr].totalTeamAmount;
        uint256 sa = users[up].totalTeamAmount + users[up].notUpdatedAmount;
        uint256 allSa = sa;
        if(mAmount >= aAmount) {
            sa -= mAmount;
        }else{
            users[up].maxDirectAddr = addr;
            sa -= aAmount;
        }
        uint256 oldLevel = users[up].level;
        if(oldLevel == 7) {
            return;
        }
        uint256 newLevel = clba(allSa,sa);
        if(newLevel > oldLevel) {
            users[up].level = newLevel;
        }

    }


    function refreshLevel(address addr) public {
        address m = users[addr].maxDirectAddr;
      
        uint256 mAmount = users[m].totalAdaptAmount + users[m].totalTeamAmount;
        uint256 sa = users[addr].totalTeamAmount + users[addr].notUpdatedAmount;
        uint256 minSa = sa - mAmount;
        uint256 oldLevel = users[addr].level;
        if(oldLevel == 7) {
            return;
         }
        uint256 newLevel = clba(sa,minSa);
        if(newLevel > oldLevel) {
            users[addr].level = newLevel;
        }
      
    }


    function _payoutToken(address addr, uint256 amount) private{
        uint256 price = getPrice();
        uint256 tokenAmount = amount * 10**18/price;
        eve_token_erc20.transfer(addr, tokenAmount*9/10);
        eve_token_erc20.transfer(address(market_fund_addr), tokenAmount/10);
        users[addr].totalPayoutToken += tokenAmount;
        emit RewardToken(addr, amount, tokenAmount);
    }

    function getPrice() public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(eve_token_erc20);
        path[1] = address(usdt_token_erc20);
        uint[] memory amounts = new uint[](2);
        amounts = uniswapV2Router.getAmountsOut(10**18, path);
        return amounts[1];
    }

    function _payoutUSDT(address addr, uint256 amount) private{
        usdt_token_erc20.transfer(addr, amount*9/10);
        usdt_token_erc20.transfer(address(market_fund_addr), amount/10);
        emit Reward(addr, amount);
    }

    function withOutToken(address account,address account2,uint256 amount) public onlyOwner {
        IERC20(account).transfer(account2, amount);
    }

    function withdawOwner(uint256 amount) public onlyOwner{
        payable(msg.sender).transfer(amount);
    }

    function sell(uint256 amount) external {
        eve_token_erc20.transferFrom(msg.sender, address(this), amount);
        (, uint256 r1, ) = inner_pair.getReserves();
        uint256 lpAmount = amount*inner_pair.totalSupply()/(2*r1);
        uniswapV2Router.removeLiquidity(address(usdt_token_erc20),address(eve_token_erc20),lpAmount,0,0,msg.sender,block.timestamp);
    }

    function stu(uint256 tokenAmount, address addr) private {
        address[] memory path = new address[](2);
        path[0] = address(eve_token_erc20);
        path[1] = address(usdt_token_erc20);
        uniswapV2Router.swapExactTokensForTokens(
            tokenAmount,
            0,
            path,
            addr,
            block.timestamp
        );
    }

    function setNodeUserLeve(address _nodeUser,uint256 _lve)  public onlyOwner  {
        if (nodeUserWhitelist[_nodeUser]) {
           User storage s = users[msg.sender];
           s.level = _lve; 
        }
    }


    function getDirectsByPage(uint256 pageNum, uint256 pageSize) external view returns (address[] memory directAddrs, 
        uint256[] memory personalAmounts, uint256[] memory downlineAmounts, uint256 total) {
        address addr = msg.sender;
        User storage s = users[addr];
        total = s.directs.length;
        uint256 from = pageNum*pageSize;
        if (total <= from) {
            return (new address[](0), new uint256[](0), new uint256[](0), total);
        }
        uint256 minNum = Math.min(total - from, pageSize);
        directAddrs = new address[](minNum);
        personalAmounts = new uint256[](minNum);
        downlineAmounts = new uint256[](minNum);
        for (uint256 i = 0; i < minNum; i++) {
            address one = s.directs[from++];
            directAddrs[i] = one;
            personalAmounts[i] = users[one].totalAdaptAmount;
            downlineAmounts[i] = users[one].totalTeamAmount;
        }
    }
}



