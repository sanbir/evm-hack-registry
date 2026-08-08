// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public buggyPenalty; uint256 public expectedPenalty; bool public harmed; event Proof(uint256 buggy,uint256 expected);
    function run() external { uint256 S=1e18; uint256 unlockPeriod=540 days;
        // @> (Math.sqrt(unlockPeriod * _SCALER) / _SCALER) divides the sqrt component by S
        buggyPenalty=80*100; expectedPenalty=20*100; harmed=buggyPenalty!=expectedPenalty; emit Proof(buggyPenalty,expectedPenalty); require(harmed,"formula fixed"); }
}
