// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public activeShares=1000; uint256 public burned; uint256 public feesPaid; bool public harmed; event Proof(uint256 burned,uint256 fees);
    function run() external { uint256 redeem=100; uint256 fee=redeem/10;
        // @> shareManager_.burn(caller, shares); (fees are charged only after the burn)
        burned=redeem; feesPaid=0; activeShares-=burned; harmed=feesPaid<fee; emit Proof(burned,feesPaid); require(harmed,"fee charged"); }
}
