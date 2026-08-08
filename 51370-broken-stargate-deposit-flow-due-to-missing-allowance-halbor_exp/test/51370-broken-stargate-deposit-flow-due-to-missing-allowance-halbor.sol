// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/* Entangle Trillion — Stargate depositLP never approves the staking contract (Halborn, #51370). */
contract MockLP { mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
 function mint(address a,uint v) external { balanceOf[a]+=v; } function approve(address s,uint v) external returns(bool){allowance[msg.sender][s]=v;return true;}
 function transferFrom(address f,address t,uint v) external returns(bool){require(allowance[f][msg.sender]>=v,"allowance");require(balanceOf[f]>=v,"balance");allowance[f][msg.sender]-=v;balanceOf[f]-=v;balanceOf[t]+=v;return true;} }
contract StargateLPStaking { MockLP public immutable lp; constructor(MockLP x){lp=x;} function deposit(uint256,uint256 amount) external { require(lp.transferFrom(msg.sender,address(this),amount),"transfer"); } }
contract StargateSynthChef { struct Pool { MockLP LPToken; uint256 stargateLPStakingPoolID; } mapping(uint32=>Pool) public pools; address public immutable master; StargateLPStaking public immutable lpStaking;
 constructor(address m,StargateLPStaking s){master=m;lpStaking=s;} modifier onlyMaster(){require(msg.sender==master,"master");_;} function addPool(uint32 id,MockLP l) external onlyMaster {pools[id]=Pool(l,4);} 
 /// @notice Deposit LP tokens to farm. Can only be called by the MASTER.
 function depositLP(uint32 poolId,uint256 lpAmount) external onlyMaster { if(lpAmount==0) revert(); Pool memory pool=pools[poolId]; lpStaking.deposit(pool.stargateLPStakingPoolID,lpAmount); // @> VULN: Chef has not approved lpStaking to pull its LP.
 // FIX: pool.LPToken.approve(address(lpStaking), lpAmount) before deposit.
 } }
contract Exploit { MockLP public lp; StargateLPStaking public staking; StargateSynthChef public chef; bool public depositBlocked;
 constructor(){lp=new MockLP();staking=new StargateLPStaking(lp);chef=new StargateSynthChef(address(this),staking);chef.addPool(1,lp);lp.mint(address(chef),100);} function run() external {try chef.depositLP(1,100){depositBlocked=false;}catch{depositBlocked=true;}require(depositBlocked,"missing allowance did not block");require(lp.balanceOf(address(chef))==100,"LP left chef");require(lp.balanceOf(address(staking))==0,"farm received LP");} }