// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILog {
    function addBlockId() external;
    function getBlockIdListCount() external view returns (uint256);
}

interface ITreasury {
    function stake(uint256 _amount, uint256 _stakeDays, bool isReward) external;
    function lpBonds(uint256 _lpFoxAmount, uint256 _stakeAmount, uint256 _stakeDays, address inviterAddress,uint256 inviterRewardAmount) external;
    function burnBonds(uint256 _burnAmount, uint256 _stakeAmount, uint256 _stakeDays, address inviterAddress,uint256 inviterRewardAmount) external;
    function redeem(uint256 _amount) external;
    function timeLock(uint256 _timeLockId, address _user, uint256 _lockDays, uint256 _amount) external;
    function fulMingingStatus() external view returns (bool);
}

interface IRewardRatioLog {
    function getRatio(uint256 _timestamp) external view returns (uint256);
    function getAlignedRatio(uint256 _timestamp) external view returns (uint256);
}

interface IReferral {
    function referralMap(address _userAddress) external view returns (address);
}

struct StakeInfo{
    uint256 stakeId;
    address user;
    uint256 stakeStartTime;
    uint256 rewardStartTime;
    uint256 stakeEndTime;
    uint256 amount;
    uint256 amountRedeemed;
    uint256 amountRewardPending;
    uint256 amountRewardClaimed;
    uint256 fulMingingStartTime;
    uint256 fulMingingEndTime;
}

contract FoxPoolBase {
    using SafeERC20 for IERC20;   

    uint256 public constant BASE_100 = 10000;
    uint256 public constant TIME_BASE = 8 hours;

    uint256 public stakeDays;
    address public treasury;

    address public logAddress;
    address public referralAddress;
    address public rewardRatioLogAddress;

    address public usdtToken;    
    address public foxToken;
    address public stakedFoxToken;    
    address public swapRouter;
    
    uint256 public rewardRateFrom;
    uint256 public rewardRateTo;   

    address public governance;

    mapping(uint256 => StakeInfo) public stakeInfoMap;
    mapping(uint256 => bool) public fulMingingDaysMap;

    // Errors
    error StakeNotExist();
    error NotOwner();

    event UserStake(
        uint256 stakeId,
        address user,
        uint256 stakeStartTime,
        uint256 rewardStartTime,
        uint256 stakeEndTime,
        uint256 amount,
        uint256 usdtAmount,
        uint256 foxPrice,
        uint256 inviterRewardAmount,
        uint256 timestamp
    );
    
    event UserRedeem(
        uint256 redeemId,
        uint256 stakeId,
        address user,
        uint256 stakeStartTime,
        uint256 rewardStartTime,
        uint256 stakeEndTime,
        uint256 amount,
        uint256 amountRedeemed,
        uint256 amountRewardPending,
        uint256 amountRewardClaimed,
        uint256 changeAmount,
        uint256 timestamp
    );

    event UserCheckpoint(
        uint256 checkpointId,
        uint256 stakeId,
        address user,
        uint256 stakeStartTime,
        uint256 rewardStartTime,
        uint256 stakeEndTime,
        uint256 amount,
        uint256 amountRedeemed,
        uint256 amountRewardPending,
        uint256 amountRewardClaimed,
        uint256 timestamp
    );

    event UserTimeLock(
        uint256 timeLockId,
        uint256 stakeId,
        address user,
        uint256 stakeStartTime,
        uint256 rewardStartTime,
        uint256 stakeEndTime,
        uint256 amount,
        uint256 amountRedeemed,
        uint256 amountRewardPending,
        uint256 amountRewardClaimed,
        uint256 changeAmount,
        uint256 timestamp
    );

    event UserStartFulMinging(
        uint256 stakeId,
        address user,
        uint256 startTime,
        uint256 endTime,
        uint256 timestamp
    );

    event UserEndFulMinging(
        uint256 stakeId,
        address user,
        uint256 timestamp
    );

    modifier onlyGovernance() {
        require(msg.sender == governance, "unauthorized access");
        _;
    }

    constructor() {
    }

    function initFoxPoolCommon(
        uint256 _stakeDays, 
        address _treasury,

        address _logAddress,
        address _referralAddress,
        address _rewardRatioLogAddress,

        address _usdtToken,
        address _foxToken,
        address _stakedFoxToken,        
        address _swapRouter,

        uint256 _rewardRateFrom,
        uint256 _rewardRateTo,
        address _governance) internal{

        stakeDays = _stakeDays;
        treasury = _treasury;

        logAddress = _logAddress;    
        referralAddress = _referralAddress;
        rewardRatioLogAddress = _rewardRatioLogAddress;

        usdtToken = _usdtToken;
        foxToken = _foxToken;
        stakedFoxToken = _stakedFoxToken;        
        swapRouter = _swapRouter;
        
        rewardRateFrom = _rewardRateFrom;
        rewardRateTo = _rewardRateTo;

        governance = _governance;

        fulMingingDaysMap[0] = true;
        fulMingingDaysMap[30] = true;
        fulMingingDaysMap[90] = true;
        fulMingingDaysMap[180] = true;
        fulMingingDaysMap[360] = true;
    }
    

    function getRewardRate(uint256 _timestamp) public view returns (uint256){
        uint256 ratio = IRewardRatioLog(rewardRatioLogAddress).getRatio(_timestamp);
        return rewardRateFrom + (rewardRateTo - rewardRateFrom) * ratio / BASE_100;
    }

    function getAlignedRewardRate(uint256 _timestamp) public view returns (uint256){
        uint256 ratio = IRewardRatioLog(rewardRatioLogAddress).getAlignedRatio(_timestamp);
        return rewardRateFrom + (rewardRateTo - rewardRateFrom) * ratio / BASE_100;
    }

    function getPendingRewardIn(uint256 timestamp, StakeInfo memory stakeInfo) internal view returns (uint256){        
        if(timestamp <= stakeInfo.rewardStartTime){
            return stakeInfo.amountRewardPending;   
        }

        uint256 stakedAmount = stakeInfo.amount - stakeInfo.amountRedeemed;
        if(stakedAmount == 0){
            return stakeInfo.amountRewardPending;
        }

        uint256 rewardRate;
        uint256 startTime = stakeInfo.rewardStartTime;        
        uint256 reward = stakeInfo.amountRewardPending;
      
        while(startTime < timestamp){                    
            rewardRate = getRewardRate(startTime);
            reward = reward + (stakedAmount + reward) * rewardRate / BASE_100;

            startTime = startTime + TIME_BASE; 
        }
        
        return reward;
    }

    function getPendingReward(uint256 _stakeId) public view returns (uint256 _timestamp, uint256 pendingReward){
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        
        return (timestamp, getPendingRewardIn(timestamp, stakeInfo));
    }

    function getTotalReward(uint256 _stakeId) public view returns (uint256 _timestamp, uint256 pendingReward){
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        
        return (timestamp, stakeInfo.amountRewardClaimed + getPendingRewardIn(timestamp, stakeInfo));
    }


    function getPendingPrincipalIn(uint256 timestamp, StakeInfo memory stakeInfo) internal pure returns (uint256){        
        if(timestamp <= stakeInfo.stakeStartTime){
            return 0;   
        }

        uint256 stakedAmount = stakeInfo.amount - stakeInfo.amountRedeemed;
        if(stakedAmount == 0){
            return 0;
        }

        if(timestamp >= stakeInfo.stakeEndTime){
            return stakedAmount;
        }

        uint256 amount = stakeInfo.amount * TIME_BASE / (stakeInfo.stakeEndTime - stakeInfo.stakeStartTime);
        amount = amount * (timestamp - stakeInfo.stakeStartTime) / TIME_BASE;

        if(amount > stakeInfo.amount){
            amount = stakeInfo.amount;
        }
        
        return amount - stakeInfo.amountRedeemed;
    }

    function getPendingPrincipal(uint256 _stakeId) public view returns (uint256 _timestamp, uint256 pendingPrincipal){
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        
        return (timestamp, getPendingPrincipalIn(timestamp, stakeInfo));
    }    

    function redeem(uint256 _stakeId) external {
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        require(stakeInfo.user == msg.sender, NotOwner()); 
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;        
        uint256 pendingPrincipal = getPendingPrincipalIn(timestamp, stakeInfo);
        require(pendingPrincipal > 0, "no pending principal");

        uint256 pendingReward = getPendingRewardIn(timestamp, stakeInfo);

        ITreasury(treasury).redeem(pendingPrincipal);
        IERC20(foxToken).safeTransfer(msg.sender, pendingPrincipal);

        uint256 amountRedeemed = stakeInfo.amountRedeemed + pendingPrincipal;

        stakeInfoMap[_stakeId].rewardStartTime = timestamp;
        stakeInfoMap[_stakeId].amountRewardPending = pendingReward;
        stakeInfoMap[_stakeId].amountRedeemed = amountRedeemed;

        uint256 redeemId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();

        emit UserRedeem(
            redeemId, 
            _stakeId, 
            stakeInfo.user, 
            stakeInfo.stakeStartTime, 
            timestamp, 
            stakeInfo.stakeEndTime, 
            stakeInfo.amount, 
            amountRedeemed, 
            pendingReward, //amountRewardPending
            stakeInfo.amountRewardClaimed, //amountRewardClaimed
            pendingPrincipal, //changeAmount
            block.timestamp);
             
    }

    function checkpoint(uint256 _stakeId) external onlyGovernance{
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE; 
        uint256 pendingReward = getPendingRewardIn(timestamp, stakeInfo);
        require(pendingReward > 0, "no pending reward");

        uint256 checkpointId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();

        stakeInfoMap[_stakeId].rewardStartTime = timestamp;
        stakeInfoMap[_stakeId].amountRewardPending = pendingReward;

        emit UserCheckpoint(
            checkpointId,
            _stakeId,
            stakeInfo.user,
            stakeInfo.stakeStartTime,
            timestamp,
            stakeInfo.stakeEndTime,
            stakeInfo.amount,
            stakeInfo.amountRedeemed,
            pendingReward, //amountRewardPending
            stakeInfo.amountRewardClaimed,
            block.timestamp
        );
    }

    function timeLock(uint256 _stakeId, uint256 _lockDays) external {
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        require(stakeInfo.user == msg.sender, NotOwner()); 
        require(stakeInfo.fulMingingStartTime == 0, "Ful mining not closed");
        
        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE; 
        uint256 pendingReward = getPendingRewardIn(timestamp, stakeInfo);
        require(pendingReward > 0, "no pending reward");

        uint256 timeLockId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();

        ITreasury(treasury).timeLock(timeLockId, msg.sender, _lockDays, pendingReward);

        uint256 amountRewardClaimed = stakeInfo.amountRewardClaimed + pendingReward;

        stakeInfoMap[_stakeId].rewardStartTime = timestamp;
        stakeInfoMap[_stakeId].amountRewardPending = 0;
        stakeInfoMap[_stakeId].amountRewardClaimed = amountRewardClaimed;

        emit UserTimeLock(
            timeLockId,
            _stakeId,
            stakeInfo.user,
            stakeInfo.stakeStartTime,
            timestamp,
            stakeInfo.stakeEndTime,
            stakeInfo.amount,
            stakeInfo.amountRedeemed,
            0, //amountRewardPending
            amountRewardClaimed, 
            pendingReward, //changeAmount
            block.timestamp
        );
    }

    function startFulMinging(uint256 _stakeId, uint256 _lockDays) external {
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        require(stakeInfo.user == msg.sender, NotOwner()); 
        require(stakeInfo.amount - stakeInfo.amountRedeemed > 0, "no stake amount");
        require(stakeInfo.fulMingingStartTime == 0, "Ful mining not closed");
        require(fulMingingDaysMap[_lockDays], "Lock days not supported");

        uint256 startTime = block.timestamp / TIME_BASE * TIME_BASE;
        uint256 endTime = startTime + _lockDays * 1 days;
        if(_lockDays == 0){
            endTime = startTime + TIME_BASE;
        }
        
        stakeInfoMap[_stakeId].fulMingingStartTime = startTime;
        stakeInfoMap[_stakeId].fulMingingEndTime = endTime;
        
        emit UserStartFulMinging(
            _stakeId,
            stakeInfo.user,
            startTime,
            endTime,
            block.timestamp
        );
    }

    function endFulMinging(uint256 _stakeId) external {
        StakeInfo memory stakeInfo = stakeInfoMap[_stakeId];
        require(stakeInfo.stakeStartTime > 0, StakeNotExist());
        require(stakeInfo.user == msg.sender, NotOwner()); 
        require(stakeInfo.fulMingingStartTime > 0, "Ful mining not started");

        uint256 timestamp = block.timestamp / TIME_BASE * TIME_BASE;
        require(timestamp >= stakeInfo.fulMingingEndTime, "Ful mining not ended");

        stakeInfoMap[_stakeId].fulMingingStartTime = 0;
        stakeInfoMap[_stakeId].fulMingingEndTime = 0;

        emit UserEndFulMinging(
            _stakeId,
            stakeInfo.user,
            block.timestamp
        );
    }
}