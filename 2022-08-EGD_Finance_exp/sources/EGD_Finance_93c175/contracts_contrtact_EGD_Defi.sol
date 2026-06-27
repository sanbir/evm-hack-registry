// SPDX-License-Identifier: MIT
pragma solidity ^ 0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../router.sol";

contract EGD_Finance is OwnableUpgradeable {
    IPancakeRouter02 public router;
    IERC20 public U;
    IERC20 public EGD;
    address public pair;
    uint startTime;
    uint[] public rate;
    address public fund;
    uint[] referRate;
    mapping(uint => uint) public dailyStake;
    uint public dailyStakeLimit;
    address wallet;
    uint stakeId;

    struct UserInfo {
        uint totalAmount;
        uint totalClaimed;
        uint[] userStakeList;
        address invitor;
        bool isRefer;
        uint refer;
        uint referReward;
    }

    mapping(address => UserInfo) public userInfo;

    struct UserSlot {
        uint totalQuota;
        uint stakeTime;
        uint leftQuota;
        uint claimTime;
        uint rates;
        uint claimedQuota;
    }

    mapping(address => mapping(uint => UserSlot)) public userSlot;
    mapping(address =>mapping(uint => uint)) public userDailyReferReward;
    mapping(address => bool) public black;
    uint[] rateList;
    event Stake(address indexed player, uint indexed amount);
    event Claim(address indexed player,uint indexed amount);
    function initialize() public initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        rate = [200, 180, 160, 140];
        startTime = block.timestamp;
        referRate = [6, 3, 1, 1, 1, 1, 1, 1, 2, 3];
        rateList = [547,493,438,383];
        dailyStakeLimit = 1000000 ether;
        wallet = 0xC8D45fF624F698FA4E745F02518f451ec4549AE8;
        fund = 0x9Ce3Aded1422A8c507DC64Ce1a0C759cf7A4289F;
        EGD = IERC20(0x202b233735bF743FA31abb8f71e641970161bF98);
        U = IERC20(0x55d398326f99059fF775485246999027B3197955);
        router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        pair = IPancakeFactory(router.factory()).getPair(address(EGD),address(U));
    }


    function setToken(address EGD_, address usdt) external onlyOwner {
        EGD = IERC20(EGD_);
        U = IERC20(usdt);
    }

    function setRouter(address addr) external onlyOwner {
        router = IPancakeRouter02(addr);
    }

    function setPair(address addr) external onlyOwner {
        pair = addr;
    }

    function setRate(uint[] memory rate_) external onlyOwner {
        rate = rate_;
    }

    function setWallet(address addr) external onlyOwner {
        wallet = addr;
    }

    function setRateList(uint[] memory list_) external onlyOwner{
        rateList = list_;
    }

    function setFund(address addr) external onlyOwner {
        fund = addr;
    }

    function withDraw(address token, address wallet_, uint amount) external onlyOwner {
        IERC20(token).transfer(wallet_, amount);
    }

    function setUserisRefer(address addr, bool b) external onlyOwner {
        userInfo[addr].isRefer = b;
    }

    function getCurrentDay() public view returns (uint){
        return (block.timestamp - block.timestamp % 86400);
    }

    function setBlack(address addr,bool b) external onlyOwner{
        black[addr] = b;
    }

    function getEGDPrice() public view returns (uint){
        uint balance1 = EGD.balanceOf(pair);
        uint balance2 = U.balanceOf(pair);
        return (balance2 * 1e18 / balance1);
    }

    function _processReBuy(uint amount) internal {
        U.approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = address(U);
        path[1] = address(EGD);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp + 720000);
    }

    function _processRefer(address addr, uint amount) internal {
        address temp = userInfo[addr].invitor;
        uint left = amount;
//        U.approve(address(router), amount * 2);
//        address[] memory path = new address[](2);
//        path[0] = address(U);
//        path[1] = address(EGD);
        for (uint i = 0; i < 10; i ++) {
            if (temp == address(0) || temp == address(this)) {
                break;
            }
            if ((userInfo[temp].refer >= i + 1 && userInfo[temp].totalAmount >= 100 ether)|| userInfo[temp].isRefer) {
                uint tempAmount = amount * referRate[i] / 20;
                U.transfer(temp,tempAmount);
//                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(tempAmount, 0, path, temp, block.timestamp + 7200000);
                userInfo[temp].referReward += tempAmount;
                userDailyReferReward[temp][getCurrentDay()] += tempAmount;
                left -= tempAmount;
            }
            temp = userInfo[temp].invitor;
        }
        if (left > 0) {
            U.transfer(wallet, left);
        }
    }

    function getUserReferReward(address addr) public view returns(uint,uint){
        return(userInfo[addr].referReward,userDailyReferReward[addr][getCurrentDay()]);
    }

    function bond(address invitor) external {
        require(userInfo[msg.sender].invitor == address(0), 'have invitor');
        require(userInfo[invitor].invitor != address(0) || invitor == fund, 'wrong invitor');
        userInfo[msg.sender].invitor = invitor;
        userInfo[invitor].refer ++;

    }

    function stake(uint amount) external {
        require(amount >= 100 ether, 'lower than limit');
        require(dailyStake[getCurrentDay()] + amount < dailyStakeLimit, 'out of daily stake limit');
        require(userInfo[msg.sender].invitor != address(0),'not have invitor');
        U.transferFrom(msg.sender, address(this), amount);
        _processReBuy(amount * 70 / 100);
        U.transfer(wallet, amount / 10);
        _processRefer(msg.sender, amount * 20 / 100);
        uint index = (block.timestamp - startTime) / 365 days;
        uint tempRate;
        if(index > 3){
            tempRate = rateList[3];
        }else{
            tempRate = rateList[index];
        }
        userSlot[msg.sender][stakeId].rates = amount * tempRate / 100000 / 86400;
        userSlot[msg.sender][stakeId].stakeTime = block.timestamp;
        userSlot[msg.sender][stakeId].claimTime = block.timestamp;
        userSlot[msg.sender][stakeId].totalQuota = amount;
        userSlot[msg.sender][stakeId].leftQuota = amount * rate[index] / 100;
        userInfo[msg.sender].userStakeList.push(stakeId);
        userInfo[msg.sender].totalAmount += amount;
        stakeId ++;
        dailyStake[getCurrentDay()] += amount;

        emit Stake(msg.sender, amount);
    }

    function calculateReward(address addr, uint slot) public view returns (uint){
        UserSlot memory info = userSlot[addr][slot];
        if (info.leftQuota == 0) {
            return 0;
        }
        uint totalRew = (block.timestamp - info.claimTime) * info.rates;
        if (totalRew >= info.leftQuota) {
            totalRew = info.leftQuota;
        }
        return totalRew;
    }

    function calculateAll(address addr) public view returns (uint){
        uint[] memory list = userInfo[addr].userStakeList;
        if (list.length == 0) {
            return 0;
        }
        uint rew;
        for (uint i = 0; i < list.length; i++) {
            rew += calculateReward(addr, list[i]);
        }
        return rew;
    }


    function getDailyStake() public view returns (uint){
        return (dailyStake[getCurrentDay()]);
    }

    function checkUserRecord(address addr) public view returns (uint[] memory total, uint[] memory stakeTime, uint[] memory claimed){
        uint[] memory list = userInfo[addr].userStakeList;
        total = new uint[](list.length);
        stakeTime = new uint[](list.length);
        claimed = new uint[](list.length);
        if (list.length == 0) {
            return (total, stakeTime, claimed);
        }
        for (uint i = 0; i < list.length; i++) {
            total[i] = userSlot[addr][list[i]].totalQuota;
            stakeTime[i] = userSlot[addr][list[i]].stakeTime;
            claimed[i] = userSlot[addr][list[i]].claimedQuota;
        }
        return (total, stakeTime, claimed);
    }

    function checkUserStakeList(address addr) public view returns (uint[] memory){
        return userInfo[addr].userStakeList;
    }

    function claimAllReward() external {
        require(userInfo[msg.sender].userStakeList.length > 0, 'no stake');
        require(!black[msg.sender],'black');
        uint[] storage list = userInfo[msg.sender].userStakeList;
        uint rew;
        uint outAmount;
        uint range = list.length;
        for (uint i = 0; i < range; i++) {
            UserSlot storage info = userSlot[msg.sender][list[i - outAmount]];
            require(info.totalQuota != 0, 'wrong index');
            uint quota = (block.timestamp - info.claimTime) * info.rates;
            if (quota >= info.leftQuota) {
                quota = info.leftQuota;
            }
            rew += quota * 1e18 / getEGDPrice();
            info.claimTime = block.timestamp;
            info.leftQuota -= quota;
            info.claimedQuota += quota;
            if (info.leftQuota == 0) {
                userInfo[msg.sender].totalAmount -= info.totalQuota;
                delete userSlot[msg.sender][list[i - outAmount]];
                list[i - outAmount] = list[list.length - 1];
                list.pop();
                outAmount ++;
            }
        }
        userInfo[msg.sender].userStakeList = list;
        EGD.transfer(msg.sender, rew);
        userInfo[msg.sender].totalClaimed += rew;
        emit Claim(msg.sender,rew);
    }
}