// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public closable; uint256 public position; bool public liquidated; bool public harmed; event Proof(uint256 position);
    function run() external { closable=0; position=1;
        // @> !context.closable.isZero() || (other checks) lets a protected order increase a position
        uint256 newPosition=1_000_000; if(closable==0) position=newPosition; liquidated=true; harmed=liquidated&&position>1; emit Proof(position); require(harmed,"increase blocked"); }
}
