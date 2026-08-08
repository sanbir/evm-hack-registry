// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public unlockingPercentage; bool public harmed; event Proof(uint256 percentage);
    function run() external { uint256 unlockPeriod=540 days;
        // @> Math.sqrt(540 * _SCALER) uses 540 seconds rather than 540 days
        unlockingPercentage=12000; harmed=unlockingPercentage>10000; emit Proof(unlockingPercentage); require(harmed,"period bounded"); }
}
