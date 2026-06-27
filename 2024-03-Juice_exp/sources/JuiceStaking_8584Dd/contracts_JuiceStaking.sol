// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract JuiceStaking is Ownable{
    using SafeERC20 for IERC20;
	
    address public Juice;
	
	uint256 public JuiceStaked;
	uint256 public precisionFactor;
	uint256 public rewardPerSecond;
	uint256 public lastRewardUpdateTime;
	uint256 public stakingStartTime;
	uint256 public stakingEndTime;
	uint256 public rewardPerShare;
	
	struct StakingInfo {
	  uint256 stakedAmount; 
	  uint256 startTime;
	  uint256 endTime;
	  uint256 stakingWeek;
	  uint256 rewardDebt;
	  uint256 unstakeStatus;
    }
	
	mapping(address => mapping(uint256 => StakingInfo)) public mapStakingInfo;
	mapping(address => uint256) public stakingCount;
	
	event Stake(address staker, uint256 amount);
	event Unstake(address staker, uint256 amount);
	event Harvest(address staker, uint256 amount);
	event StakingStart(uint256 startTime, uint256 endTime, uint256 tokens);
	
    constructor() {
	   Juice = address(0xdE5d2530A877871F6f0fc240b9fCE117246DaDae);
       precisionFactor = 1 * 10**18;
    }
	
	function stake(uint256 amount, uint256 stakeWeek) external {
	    require(IERC20(Juice).balanceOf(address(msg.sender)) >= amount, "Balance not available for staking");
		require(stakeWeek > 0, "stakeWeek must be greater than or equal to one");
		require(stakingStartTime > 0, "Staking is not started yet");
		require(stakingEndTime > block.timestamp, "Staking is closed");
		
		_updatePool();
		
		uint256 stakeCount = stakingCount[address(msg.sender)];
		
		IERC20(Juice).safeTransferFrom(address(msg.sender), address(this), amount);
		JuiceStaked += amount;
		stakingCount[address(msg.sender)] += 1;
		
		mapStakingInfo[address(msg.sender)][stakeCount].stakedAmount = amount;
		mapStakingInfo[address(msg.sender)][stakeCount].startTime = block.timestamp;
		mapStakingInfo[address(msg.sender)][stakeCount].endTime = block.timestamp + (stakeWeek * 7 days);
		mapStakingInfo[address(msg.sender)][stakeCount].stakingWeek = stakeWeek;
		mapStakingInfo[address(msg.sender)][stakeCount].rewardDebt = (amount * rewardPerShare) / precisionFactor;
        emit Stake(address(msg.sender), amount);
    }
	
	function unstake(uint256 stakeCount) external {
	    require(mapStakingInfo[address(msg.sender)][stakeCount].stakedAmount > 0, "Staking not found");
		require(mapStakingInfo[address(msg.sender)][stakeCount].unstakeStatus == 0, "Staking already unstake");
		
		_updatePool();
		
	    if(block.timestamp >= mapStakingInfo[address(msg.sender)][stakeCount].endTime) 
		{
		    (uint256 pending, uint256 bonus) = pendingReward(address(msg.sender), stakeCount);
		    uint256 amount = mapStakingInfo[address(msg.sender)][stakeCount].stakedAmount;
			
		    IERC20(Juice).safeTransfer(address(msg.sender), (amount + pending + bonus));
			
		    JuiceStaked -= amount;
		    mapStakingInfo[address(msg.sender)][stakeCount].unstakeStatus = 1;
		    mapStakingInfo[address(msg.sender)][stakeCount].rewardDebt += pending;
		    emit Unstake(address(msg.sender), (amount + pending + bonus));
        }
    }
	
	function harvest(uint256 stakeCount) external {
	    require(mapStakingInfo[address(msg.sender)][stakeCount].stakedAmount > 0, "Staking not found");
		require(mapStakingInfo[address(msg.sender)][stakeCount].unstakeStatus == 0, "Staking already unstake");
		
		_updatePool();
		
		(uint256 pending, uint256 bonus) = pendingReward(address(msg.sender), stakeCount);
		IERC20(Juice).safeTransfer(address(msg.sender), (pending + bonus));
		
		mapStakingInfo[address(msg.sender)][stakeCount].rewardDebt += pending;
        emit Harvest(msg.sender, (pending + bonus));
    }
	
	function _updatePool() internal {
        if(block.timestamp <= lastRewardUpdateTime) 
		{
           return;
        }
        if(JuiceStaked == 0) 
		{
           lastRewardUpdateTime = block.timestamp;
           return;
        }
        uint256 multiplier = _getMultiplier(lastRewardUpdateTime, block.timestamp);
        uint256 stakingReward = multiplier * rewardPerSecond;
        rewardPerShare = rewardPerShare + (stakingReward * precisionFactor) / JuiceStaked;
        lastRewardUpdateTime = block.timestamp;
    }
	
	function _getMultiplier(uint256 startTime, uint256 endTime) internal view returns (uint256) {
        if(endTime <= stakingEndTime) 
		{
            return endTime - startTime;
        } 
		else if(startTime >= stakingEndTime) 
		{
            return 0;
        } 
		else 
		{
           return stakingEndTime - startTime;
        }
    }
	
	function pendingReward(address staker, uint256 stakeCount) public view returns (uint256, uint256) {
	
		if(mapStakingInfo[address(staker)][stakeCount].stakedAmount > 0 && mapStakingInfo[address(staker)][stakeCount].unstakeStatus == 0)
		{
		    if(block.timestamp > lastRewardUpdateTime && JuiceStaked != 0)
			{
			   uint256 multiplier = _getMultiplier(lastRewardUpdateTime, block.timestamp);
			   uint256 stakingReward = multiplier * rewardPerSecond;
			   uint256 adjustedTokenPerShare = rewardPerShare + (stakingReward * precisionFactor) / JuiceStaked;
			   
			   uint256 pending = (((mapStakingInfo[address(staker)][stakeCount].stakedAmount * adjustedTokenPerShare) / precisionFactor) - mapStakingInfo[address(staker)][stakeCount].rewardDebt);
		       uint256 bonus = ((pending * (mapStakingInfo[address(staker)][stakeCount].stakingWeek - 1) * 9) / 100);
			   return (pending, bonus);
			}
			else
			{
			   uint256 pending = (((mapStakingInfo[address(staker)][stakeCount].stakedAmount * rewardPerShare) / precisionFactor) - mapStakingInfo[address(staker)][stakeCount].rewardDebt);
		       uint256 bonus = ((pending * (mapStakingInfo[address(staker)][stakeCount].stakingWeek - 1) * 9) / 100);
			   return (pending, bonus);
			}
        } 
		else 
		{
		    return (0, 0);
		}
    }
	
	function startStaking(uint256 rewardTokens) external onlyOwner {
	    require(stakingStartTime == 0, "Staking already started");
	    require(rewardTokens > 0, "Reward tokens not found");
		
		IERC20(Juice).safeTransferFrom(address(msg.sender), address(this), rewardTokens);
		
	    stakingStartTime = block.timestamp;
		stakingEndTime = block.timestamp + 90 days;
		lastRewardUpdateTime = block.timestamp;
		rewardPerSecond = rewardTokens / (stakingEndTime - stakingStartTime);
		emit StakingStart(stakingStartTime, stakingEndTime, rewardTokens);
    }
	
	function rescueReward(address receiver) public onlyOwner {
	   require(receiver != address(0), "address cannot be zero");
	   IERC20(Juice).safeTransfer(address(receiver), (IERC20(Juice).balanceOf(address(this)) - JuiceStaked));
    }
}