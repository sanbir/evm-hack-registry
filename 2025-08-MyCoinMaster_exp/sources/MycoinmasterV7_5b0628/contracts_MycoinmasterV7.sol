// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.9;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IBEP20Token {
    function mintTokens(
        address receipient,
        uint256 tokenAmount
    ) external returns (bool);
    function transfer(
        address _to,
        uint256 _value
    ) external returns (bool success);
    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burnInternal(
        address _user,
        uint256 _value
    ) external returns (bool);
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool);
}
interface USDT {
    function mintTokens(
        address receipient,
        uint256 tokenAmount
    ) external returns (bool);
    function transfer(
        address _to,
        uint256 _value
    ) external returns (bool success);
    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burnInternal(
        address _user,
        uint256 _value
    ) external returns (bool);
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool);
}

/**
 * Network: bsc
 * Aggregator: BNB/USD
 * Address: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE  // Test - 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
 */

contract MycoinmasterV7 {
    AggregatorV3Interface internal priceFeed;
    IBEP20Token public tokenContract;
    USDT public usdtContract;
    using SafeMath for uint256;
    using SafeMath for uint;

    struct UserTX {
        uint tokenAmount;
        uint bnbAmount;
        uint usdtAmount;
        uint time;
        string action;
    }

    struct User {
        uint totalBuy;
        address sponsor;
        uint refBonusUSD;
        uint refBonusBnb;
        uint[10] refs;
    }

    struct LockHistory {
        uint tokenLocked;
        uint perDayPer;
        uint checkPoint;
        uint LockTime;
        uint tokenTaken;
    }

    bool public started;
    bool private IsInitinalized;
    address payable public admin;
    uint public tokenPriceUsd;
    uint public currentSuppy;
    uint public targetSuppy;
    uint public maxSuppy;
    uint public increaMent;
    uint public totalSuppy;
    uint public timeStamp;
    uint public withdrawPer;
    uint public minDeposit;
    uint public PERCENTS_DIVIDER;
    uint public systemWithDrawToken;
    uint public systemWithDrawUsdtIncome;
    uint public systemWithDrawBnbIncome;
    uint public systemDepositBNB;
    uint public systemDepositUsdt;
    uint public systemTransferTOadminUsdt;
    uint public systemTransferTOadminBNB;
    uint public systemTotalMint;
    uint public baseDivider;
    mapping(address => UserTX[]) public userTXDetails;
    mapping(address => LockHistory[]) public lockHistory;
    mapping(uint => uint) public dayWisesale;
    mapping(address => User) public users;
    uint[10] public refBonusPer;
    uint[10] public reqDirect;
    address payable public feeRev;
    uint public globalDistributionPer;
    uint public dailyLimit;
    uint public contractDeployMent;
    bool public saleOFFStatus;
    uint public globalTime;

     struct SwapHistory {
        uint token;
        uint fee;
        uint usdt;
        uint actualUSDT;
        uint time;
    }
    mapping(address => SwapHistory[]) public swapHistory;
    function initinalize(
        address payable _admin,
        IBEP20Token _tokenContract,
        USDT _usdContract
    ) external {
        require(IsInitinalized == false);
        admin = _admin;
        tokenContract = _tokenContract;
        timeStamp = 1 days;
        contractDeployMent = block.timestamp;
        minDeposit = 500 * 1e8;
        increaMent = 360000000;
        PERCENTS_DIVIDER = 100;
        baseDivider = 10000;
        globalDistributionPer = 50;
        refBonusPer = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        reqDirect = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        tokenPriceUsd = 10000000;
        usdtContract = _usdContract;
        priceFeed = AggregatorV3Interface(
            0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
        );
        IsInitinalized = true;
    }

    function buy(uint _tokens, address _sponsor, uint buyType) public payable {
        User storage user = users[msg.sender];
        uint tokenTT = _tokens;
        uint curDay = getDay(contractDeployMent);
        require(dayWisesale[curDay].add(tokenTT) <= dailyLimit, "Sale is over");
        require(saleOFFStatus == false, "Sale is Off");
        (, uint bnbAmount, uint price, uint usd) = getSwapData(_tokens);
        uint usdt = usd * 1e10;
        require(_tokens >= minDeposit, "required!");
        if (buyType == 0) {
            require(msg.value >= bnbAmount, "bnb not match!");
        } else {
            uint bal = usdtContract.balanceOf(msg.sender);
            require(bal >= usdt, "ss");
        }

        require(_tokens >= 10*1e8, "required!");
        if (users[_sponsor].totalBuy == 0) {
            _sponsor = admin;
        }
        if (user.sponsor == address(0) && admin != msg.sender) {
            user.sponsor = _sponsor;
        }
        uint airdopAmount = _tokens.mul(1).div(100);
        lock(_tokens, msg.sender);
        if (buyType == 0) {
            systemDepositBNB += msg.value;
            userTXDetails[msg.sender].push(
                UserTX(_tokens, bnbAmount, usdt, block.timestamp, "BNB TO MYC")
            );
        } else {
            systemDepositUsdt += usdt;
            userTXDetails[msg.sender].push(
                UserTX(_tokens, bnbAmount, usdt, block.timestamp, "USDT TO MYC")
            );
            usdtContract.transferFrom(msg.sender, address(this), usdt);
        }
        user.totalBuy += tokenTT;
        dayWisesale[curDay] = dayWisesale[curDay].add(tokenTT);
        address upline = user.sponsor;

        for (uint i = 0; i < refBonusPer.length; i++) {
            if (upline != address(0)) {
                if (user.totalBuy == 0) {
                    users[upline].refs[i] += 1;
                }

                if (
                    tokenTT.mul(refBonusPer[i]).div(baseDivider) > 0 &&
                    users[upline].refs[0] >= reqDirect[i]
                ) {
                    users[upline].refBonusUSD = users[upline].refBonusUSD.add(
                        tokenTT.mul(refBonusPer[i]).div(baseDivider)
                    );

                    tokenContract.mintTokens(
                        upline,
                        tokenTT.mul(refBonusPer[i]).div(baseDivider)
                    );
                }
            } else break;
            upline = users[upline].sponsor;
        }
        tokenContract.mintTokens(msg.sender, airdopAmount);
    }

    function buyBYAdmin(uint _tokens, address _sponsor,address _user) public payable {
        User storage user = users[_user];
        uint curDay = getDay(contractDeployMent);
        require(dayWisesale[curDay].add(_tokens) <= dailyLimit, "Sale is over");
        require(saleOFFStatus == false, "Sale is Off");

        require(_tokens >= minDeposit, "required!");
        if (users[_sponsor].totalBuy == 0) {
            _sponsor = admin;
        }
        if (user.sponsor == address(0) && admin != _user) {
            user.sponsor = _sponsor;
        }
uint airdopAmount = _tokens.mul(1).div(100);
        lock(_tokens, _user);
   
       
            userTXDetails[_user].push(
                UserTX(_tokens, 0, 0, block.timestamp, "By admin TO MYC")
            );
       
        user.totalBuy += _tokens;
        dayWisesale[curDay] = dayWisesale[curDay].add(_tokens);
        address upline = user.sponsor;

        for (uint i = 0; i < refBonusPer.length; i++) {
            if (upline != address(0)) {
                if (user.totalBuy == 0) {
                    users[upline].refs[i] += 1;
                }

                if (
                    _tokens.mul(refBonusPer[i]).div(baseDivider) > 0 &&
                    users[upline].refs[0] >= reqDirect[i]
                ) {
                    users[upline].refBonusUSD = users[upline].refBonusUSD.add(
                        _tokens.mul(refBonusPer[i]).div(baseDivider)
                    );

                    tokenContract.mintTokens(
                        upline,
                        _tokens.mul(refBonusPer[i]).div(baseDivider)
                    );
                }
            } else break;
            upline = users[upline].sponsor;
        }
        tokenContract.mintTokens(_user, airdopAmount);
    }

    function lock(uint token, address _user) internal {
        lockHistory[_user].push(
            LockHistory(token, 0, block.timestamp, block.timestamp, 0)
        );
        systemTotalMint += token;
        tokenContract.mintTokens(address(this), token);
    }

    function getCurrentPostion(
        address _user,
        uint index
    ) public view returns (uint incomeToken) {
        LockHistory storage pkg = lockHistory[_user][index];
        uint from = pkg.checkPoint;
        if(globalTime>from ){
            from = globalTime;
        }
        uint per = globalDistributionPer;
        if (pkg.perDayPer > 0) {
            per = pkg.perDayPer;
        }
        uint AmountToken = pkg.tokenLocked.mul(per).div(baseDivider);
        uint perSecToken = AmountToken.div(timeStamp);
        if (block.timestamp > from) {
            incomeToken = (block.timestamp.sub(from)).mul(perSecToken);

            if (pkg.tokenTaken.add(incomeToken) > pkg.tokenLocked) {
                incomeToken = pkg.tokenLocked.sub(pkg.tokenTaken);
            }
        }
    }

    function withdraw(uint index) public {
        LockHistory storage pkg = lockHistory[msg.sender][index];
        uint incometoken = getCurrentPostion(msg.sender, index);
        require((incometoken > 0), "s");
        pkg.tokenTaken += incometoken;
        systemWithDrawToken += incometoken;
        pkg.checkPoint = block.timestamp;
        tokenContract.mintTokens(msg.sender, incometoken);
    }

    function getDay(uint _from) public view returns (uint _day) {
        _day = (block.timestamp.sub(_from)).div(timeStamp);
        return _day;
    }

    function getSwapData(
        uint _tokens
    )
        public
        view
        returns (uint tokenAmount, uint bnbAmount, uint price, uint usd)
    {
        if (tokenPriceUsd > 0) {
            uint tokenPrice = tokenPriceUsd;
            usd = (_tokens * tokenPrice) / 1e8;
            price = tokenPrice;
            bnbAmount = getCalculatedBnbRecieved(usd);
            tokenAmount = _tokens;
        }
    }


    function swap(uint _tokens) public {
        require(_tokens>=1e8,"ss");
        (,,, uint usd) = getSwapData(_tokens);
         uint usdt = usd * 1e10;
         uint fee =  usdt.mul(50).div(baseDivider);
         swapHistory[msg.sender].push(SwapHistory(
            _tokens,
            fee,
            usdt.sub(fee),
            usdt,
            block.timestamp
         ));
         tokenContract.transferFrom(msg.sender, address(this),_tokens);
         usdtContract.transfer(msg.sender,usdt.sub(fee));
        

    }

    function changeSettings(uint _minDeposit) public {
        require(msg.sender == admin, "No Permission");
        minDeposit = _minDeposit;
    }

    function changeSaleSettings(uint _limit) public {
        require(msg.sender == admin, "No Permission");
        dailyLimit = _limit;
    }

    function updateSale() public {
        require(msg.sender == admin, "No Permission");
        saleOFFStatus = !saleOFFStatus;
    }

    function changeRefReqSettings(uint[10] memory data) public {
        require(msg.sender == admin, "No Permission");
        reqDirect = data;
    }

    function getLockHistory(
        address _user
    ) public view returns (LockHistory[] memory data) {
        data = lockHistory[_user];
    }
    function getSwapHistory(
        address _user
    ) public view returns (SwapHistory[] memory data) {
        data = swapHistory[_user];
    }
    function getUserTX(
        address _user
    ) public view returns (UserTX[] memory data) {
        data = userTXDetails[_user];
    }

    function updateTokenPrice(uint _price) public {
        require(msg.sender == admin, "No Permission");
        tokenPriceUsd = _price;
    }
    function changeAdmin(address _admin) public {
        require(msg.sender == admin, "No Permission");
        admin = payable(_admin);
    }
    function changeRefBonus(uint[10] memory data) public {
        require(msg.sender == admin, "No Permission");
        refBonusPer = data;
    }
    function changeGlobaldistribution(uint _globalDistributionPer) public {
        require(msg.sender == admin, "No Permission");
        globalDistributionPer = _globalDistributionPer;
    }
    function changeGlobalTime() public {
        require(msg.sender == admin, "No Permission");
        globalTime = block.timestamp;
    }

    function payBack(address _to, uint _amount, uint _type) public {
        require(admin == msg.sender, "Admin what?");
        if (_type == 0) {
            payable(_to).transfer(_amount);
        } else if (_type == 1) {
            tokenContract.transfer(_to, _amount);
        } else if (_type == 2) {
            usdtContract.transfer(_to, _amount);
        }
    }

    function getLatestPrice() public view returns (int) {
        (
            ,
            /* uint80 roundID */ int price /*uint startedAt */ /*uint timeStamp*/ /* uint80 answeredInRound*/,
            ,
            ,

        ) = priceFeed.latestRoundData();
        return price;
    }

    function TotalusdPrice(int _amount) public view returns (int) {
        int usdt = getLatestPrice();
        return (usdt * _amount) / 1e18;
    }

    function getCalculatedBnbRecieved(
        uint256 _amount
    ) public view returns (uint256) {
        uint256 usdt = uint256(getLatestPrice());
        uint256 recieved_bnb = (((_amount * 1e18) / usdt) * 1e18) / 1e18;
        return recieved_bnb;
    }
}

library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath mul failed");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // assert(b > 0); // Solidity automatically throws when dividing by 0
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath sub failed");
        return a - b;
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath add failed");
        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b == 0, "SafeMath add failed");
        return (a % b);
    }
}
