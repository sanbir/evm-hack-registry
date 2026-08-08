// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public recorded; uint256 public actual; bool public harmed; event Proof(uint256 recorded,uint256 actual);
    function run() external { uint256 oldPrincipal=100; uint256 oldIndex=1e18; uint256 currentIndex=2e18; uint256 nextBorrow=10;
        // @> userBorrows[index].principle = userBorrows[index].principle + payload.amount;
        recorded=oldPrincipal+nextBorrow; actual=(oldPrincipal*currentIndex/oldIndex)+nextBorrow; harmed=recorded<actual; emit Proof(recorded,actual); require(harmed,"interest not lost"); }
}
