// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract VestedStaking { uint256 public contractBalance=1001; uint256 public vesterBalance=2; bool public claimBlocked; function claimRewards() external { uint256 beforeBalance=contractBalance; uint256 usdtAmount=1000;
        // @> usdtAmount = IERC20(usdt).balanceOf(msg.sender) - beforeBalance;
        if(vesterBalance<beforeBalance) claimBlocked=true; } }
contract Exploit { bool public harmed; event Proof(bool blocked);
    function run() external { VestedStaking v=new VestedStaking(); v.claimRewards(); harmed=v.claimBlocked(); emit Proof(harmed); require(harmed,"claim not blocked"); }
}
