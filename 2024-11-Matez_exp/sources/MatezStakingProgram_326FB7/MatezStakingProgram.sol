//SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "./IUniswapV3Factory.sol";
import "./OracleLibrary.sol";

interface BEP20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address tokenOwner) external view returns (uint balance);
    function allowance(address tokenOwner, address spender) external view returns (uint remaining);
    function transfer(address to, uint tokens) external returns (bool success);
    function approve(address spender, uint tokens) external returns (bool success);
    function transferFrom(address from, address to, uint tokens) external returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) { return 0; }
        uint256 c = a * b;
        require(c / a == b);
        return c;
    }
    function div(uint256 a , uint256 b) internal pure returns (uint256) {
        require(b > 0);
        uint256 c = a / b;
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a);
        uint256 c = a - b;
        return c;
    }
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a);
        return c;
    }
}
contract MatezStakingProgram {

    address public immutable token0;
    address public immutable token1;
    address public immutable pool;

    constructor(
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee
    ) {

        owner = msg.sender;
        token0 = _token0;
        token1 = _token1;

        address _pool = IUniswapV3Factory(_factory).getPool(
            _token0,
            _token1,
            _fee
        );
        require(_pool != address(0), "pool doesn't exist");

        pool = _pool;
    }

    function estimateAmountOut(
        address tokenIn,
        uint128 amountIn,
        uint32 secondsAgo
    ) public view returns (uint256) {
        require(tokenIn == token0 || tokenIn == token1, "invalid token");

        address tokenOut = tokenIn == token0 ? token1 : token0;

        // (int24 tick, ) = OracleLibrary.consult(pool, secondsAgo);

        // Code copied from OracleLibrary.sol, consult()
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        // int56 since tick  time = int24  uint32
        // 56 = 24 + 32
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(
            secondsAgos
        );

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        // int56 / uint32 = int24
        int24 tick = int24(tickCumulativesDelta / secondsAgo);
        // Always round to negative infinity
        /*
        int doesn't round down when it is negative

        int56 a = -3
        -3 / 10 = -3.3333... so round down to -4
        but we get
        a / 10 = -3

        so if tickCumulativeDelta < 0 and division has remainder, then round
        down
        */
        if (
            tickCumulativesDelta < 0 && (tickCumulativesDelta % secondsAgo != 0)
        ) {
            tick--;
        }

        uint256 amountOut = OracleLibrary.getQuoteAtTick(
            tick,
            amountIn,
            tokenIn,
            tokenOut
        );
        return amountOut;
    }
    using SafeMath for uint256;
    BEP20 public depositToken;
    uint256 public totalUsers;
    address public owner;




    event direct_Income(address Owner,uint256 from ,uint256 amount,uint40 level);
    event upgrade_package(uint256 Owner,uint256 pkgId);
    event Register(uint256 userId,address usr,uint256 sponsor);
    event ClaimCall(uint256 userId,uint256 amount,uint40 Ctype);

    modifier onlyOwner() {
        require(msg.sender== owner,"Only Owner Can Execute this!");
        _;
    }
    

    struct User{
        uint256 id;
        address sponsor;
        uint40 directs;
        uint40 gen;
        uint256 selfInvest;
        uint256 directInvest;
        uint256 teamInvest;
        uint256 balance;
        uint40 invest_count;
        bool ldty_status;
        uint256 total_income;
        uint40 lastclaim;
    }

    struct Income{
        uint256 level;
        uint256 roi;
        uint256 reward;
    }

     struct Order{
        uint256 amount;
        uint256 claimed;
        uint40 timestamp;
        uint40 last_claim;
        bool status;

    }

    mapping (uint256 => address ) public idToAddress;
    mapping (address => uint256 ) public addressToId;
    mapping (address => mapping (uint40 => Order)) public orders;
    mapping (address => User ) public users;
    mapping (address => mapping (uint40 =>bool) ) public rewardStatus;
    mapping (address => Income ) public incomes;
    uint256[] public level = [0,40,20,10,4,4,4,4,4,4,4,2,2,2,2,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1];

    uint256[] public selfBrequired = [0,500e18,500e18,1000e18,1000e18,2500e18,2500e18,5000e18,5000e18];
    uint256[] public teamDrequired = [0,5,8,10,10,10,10,10,10];
    uint256[] public teamrequired = [0,15,25,50,100,200,500,1000,2500];
    uint256[] public businessDrequired = [0,1000e18,2000e18,5000e18,10000e18,15000e18,20000e18,25000e18,50000e18];
    uint256[] public businessTrequired = [0,5000e18,20000e18,50000e18,100000e18,500000e18,1500000e18,5000000e18,10000000e18];
    uint256[] public reward = [0,200e18,500e18,2000e18,5000e18,10000e18,25000e18,100000e18,300000e18];

    function init(address _owner,address _depositToken ) public onlyOwner() {
        totalUsers++;
        users[_owner].id =  1;
        depositToken=BEP20(_depositToken);
        addressToId[_owner] = totalUsers;
        idToAddress[totalUsers]=_owner;

        emit Register(totalUsers,msg.sender,0);
        // emit upgrade_package(totalUsers,6);
        // emit ClaimCall(totalUsers,1,1);

    }


    function register(address sponsor) public {
        require(users[sponsor].id != 0,"Sponsor not exists!");
        require(users[msg.sender].id == 0,"User already exists!");
        totalUsers++;
        addressToId[msg.sender] = totalUsers;
        idToAddress[totalUsers]=msg.sender;
        users[msg.sender].id=totalUsers;
        users[msg.sender].sponsor=sponsor;
        // users[sponsor].directs++;
        // addteam(sponsor);
        emit Register(totalUsers,msg.sender,addressToId[sponsor]);
    }

    // function AchievementClaim(uint40 rewardid) public {
        
    //     require(users[msg.sender].selfInvest>=selfBrequired[rewardid] && users[msg.sender].teamInvest>=businessTrequired[rewardid] && users[msg.sender].directs>=teamDrequired[rewardid] && users[msg.sender].gen>=teamrequired[rewardid] && users[msg.sender].directInvest>=businessDrequired[rewardid] && rewardStatus[msg.sender][rewardid]==false ,"You Can Not Claim for reward.");

    //     rewardStatus[msg.sender][rewardid]=true;
    //     //users[msg.sender].balance += reward[rewardid];
    //     uint256 amntin = estimateAmountOut(address(token0),uint128(reward[rewardid]),1);
    //     depositToken.transfer(msg.sender,amntin);
    //     incomes[msg.sender].reward += reward[rewardid];
    //     emit ClaimCall(addressToId[msg.sender],reward[rewardid],3);
    // }

    function stake(uint256 amnt) public {
        require(users[msg.sender].id != 0  ,"Register Before Deposit!");
        
        users[msg.sender].invest_count++;
        address sponsor = users[msg.sender].sponsor;
        if(users[msg.sender].invest_count==1){
            users[sponsor].directs++;
            addteam(sponsor);
        }
        uint256 amntin = estimateAmountOut(address(token1),uint128(amnt),1);
        depositToken.transferFrom(msg.sender, address(this), amntin);
        users[msg.sender].selfInvest += amnt;
         

        users[sponsor].directInvest += amnt;

        uint40 o_id = users[msg.sender].invest_count;

        orders[msg.sender][o_id].amount = amnt;
        orders[msg.sender][o_id].timestamp = uint40(block.timestamp);
        orders[msg.sender][o_id].last_claim =  uint40(block.timestamp);
        orders[msg.sender][o_id].status =  true;

        updateDis(msg.sender,amnt);
        emit upgrade_package(users[msg.sender].id,amnt);
    }

    function updateDis(address user,uint256 _pkg) internal{
        address sponsor = users[user].sponsor;
        for(uint256 i = 1; i<=30 ; i++){
            if(users[sponsor].id!=0){
                    users[sponsor].teamInvest += _pkg;

            }
            sponsor = users[sponsor].sponsor;
        }
    }

    uint40 intervl = 1 days;

    function checkcapping(address usr) internal view returns(uint256){
        uint256 incsome = users[usr].total_income;
        uint256 invest = users[usr].selfInvest*3;
        uint256 ret = 0;
        if(invest>incsome){
            return invest-incsome;
        }else{
            return ret;
        }

    }
    

    // function StakingClaim(uint40 pkgid) public {

    //     require((uint40(block.timestamp)-orders[msg.sender][pkgid].last_claim)/intervl >= 1 , "You Do not have any claim.");
    //     require(users[msg.sender].total_income < (users[msg.sender].selfInvest*3) , "You Do not have any claim.");

    //     uint40 ttldays = (uint40(block.timestamp)-orders[msg.sender][pkgid].timestamp)/intervl;
    //     if(ttldays>600){
    //         ttldays = 600;
    //     }
    //     uint256 perday = ( orders[msg.sender][pkgid].amount * dailyPer ) / 1000;
    //     uint256 pendingamnt = (perday*ttldays) - orders[msg.sender][pkgid].claimed;
    //     require(pendingamnt >= 10e18 , "Amount Should Be minimum 10.");

    //     //users[msg.sender].balance += pendingamnt;
    //     require(checkcapping(msg.sender)>0,"You Do not have any claim.");
    //     if(checkcapping(msg.sender)<pendingamnt){
    //         pendingamnt = checkcapping(msg.sender);
    //     }
    //     uint256 amntout = estimateAmountOut(address(token0),uint128(pendingamnt),1);
    //     depositToken.transfer(msg.sender,amntout);

    //     incomes[msg.sender].roi +=pendingamnt;
    //     users[msg.sender].total_income +=pendingamnt;

    //     claimDis(msg.sender,pendingamnt);
    //     orders[msg.sender][pkgid].claimed += pendingamnt;
    //     orders[msg.sender][pkgid].last_claim = uint40(block.timestamp);

    //     emit ClaimCall(addressToId[msg.sender],pendingamnt,1);

    // }

    function claimDis(address user,uint256 _pkg) internal{
        address sponsor = users[user].sponsor;
        for(uint256 i = 1; i<=30 ; i++){
            if(users[sponsor].sponsor!=address(0)){
                if(users[sponsor].total_income<(users[sponsor].selfInvest*3)){
                    uint256 icnm=(_pkg*level[i])/100;
                    uint256 incmchk = checkcapping(sponsor);
                    if(incmchk<icnm){
                        icnm = incmchk;
                        for(uint40 j = 1;j<=users[sponsor].invest_count;j++){
                            orders[sponsor][j].status = false;
                        }
                    }
                    users[sponsor].total_income += icnm;
                    users[sponsor].balance += icnm;
                    incomes[sponsor].level += icnm;
                }
            }
            sponsor = users[sponsor].sponsor;
        }
    }

    uint256 public dailyPer = 5;
    function changePer(uint256 _monthlyPer ) public onlyOwner(){
        dailyPer = _monthlyPer;
    }


    function addteam(address ads) internal {
        if(ads!=address(0)){
            users[ads].gen++;
            addteam(users[ads].sponsor);
        }
    }
    // function TeamStakingClaim(uint256 amount)public{
    //     require(amount>=10e18,"Amount Should Be minimum 10.");
    //     require(users[msg.sender].balance>=amount,"Insufficient Fund.");

    //     users[msg.sender].balance -= amount;
    //     users[msg.sender].lastclaim = uint40(block.timestamp);
    //     uint256 amntout = estimateAmountOut(address(token0),uint128(amount),1);
    //     depositToken.transfer(msg.sender,amntout);

    //     emit ClaimCall(addressToId[msg.sender],amount,2);
    // }

    function claim(uint40 typ,uint40 pkgid,uint256 amount)public {
        if(typ==2){
            require(amount>=10e18,"Amount Should Be minimum 10.");
            require(users[msg.sender].balance>=amount,"Insufficient Fund.");

            users[msg.sender].balance -= amount;
            users[msg.sender].lastclaim = uint40(block.timestamp);
            uint256 amntout = estimateAmountOut(address(token1),uint128(amount),1);
            depositToken.transfer(msg.sender,amntout);

            emit ClaimCall(addressToId[msg.sender],amount,2);
        }

        if(typ==1){
                require(orders[msg.sender][pkgid].status==true,"You Do not have any claim.");
                require((uint40(block.timestamp)-orders[msg.sender][pkgid].last_claim)/intervl >= 1 , "You Do not have any claim.");
                require(users[msg.sender].total_income < (users[msg.sender].selfInvest*3) , "You Do not have any claim.");

                uint40 ttldays = (uint40(block.timestamp)-orders[msg.sender][pkgid].timestamp)/intervl;
                if(ttldays>600){
                    ttldays = 600;
                }
                uint256 perday = ( orders[msg.sender][pkgid].amount * dailyPer ) / 1000;
                uint256 pendingamnt = (perday*ttldays) - orders[msg.sender][pkgid].claimed;
                require(pendingamnt >= 10e18 , "Amount Should Be minimum 10.");

                //users[msg.sender].balance += pendingamnt;
                require(checkcapping(msg.sender)>0,"You Do not have any claim.");
                if(checkcapping(msg.sender)<pendingamnt){
                    pendingamnt = checkcapping(msg.sender);
                    for(uint40 j = 1;j<=users[msg.sender].invest_count;j++){
                        orders[msg.sender][j].status = false;
                    }
                }
                uint256 amntout = estimateAmountOut(address(token1),uint128(pendingamnt),1);
                depositToken.transfer(msg.sender,amntout);

                incomes[msg.sender].roi +=pendingamnt;
                users[msg.sender].total_income +=pendingamnt;

                claimDis(msg.sender,pendingamnt);
                orders[msg.sender][pkgid].claimed += pendingamnt;
                orders[msg.sender][pkgid].last_claim = uint40(block.timestamp);

                emit ClaimCall(addressToId[msg.sender],pendingamnt,1);
        }
        if(typ==3){
            require(users[msg.sender].selfInvest>=selfBrequired[pkgid] && users[msg.sender].teamInvest>=businessTrequired[pkgid] && users[msg.sender].directs>=teamDrequired[pkgid] && users[msg.sender].gen>=teamrequired[pkgid] && users[msg.sender].directInvest>=businessDrequired[pkgid] && rewardStatus[msg.sender][pkgid]==false ,"You Can Not Claim for reward.");

            rewardStatus[msg.sender][pkgid]=true;
            //users[msg.sender].balance += reward[rewardid];
            uint256 amntin = estimateAmountOut(address(token1),uint128(reward[pkgid]),1);
            depositToken.transfer(msg.sender,amntin);
            incomes[msg.sender].reward += reward[pkgid];
            emit ClaimCall(addressToId[msg.sender],reward[pkgid],3);
        }
    }

    

}


 