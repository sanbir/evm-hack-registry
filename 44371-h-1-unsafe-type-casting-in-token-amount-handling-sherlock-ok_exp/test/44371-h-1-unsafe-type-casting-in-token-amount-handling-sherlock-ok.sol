// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public requested; uint160 public pulled; bool public harmed; event Proof(uint256 requested,uint160 pulled);
    function run() external { requested=uint256(type(uint160).max)+7;
        // @> permit2.transferFrom(owner, address(this), amount, token); where amount is uint160(amountIn)
        pulled=uint160(requested); harmed=requested!=uint256(pulled); emit Proof(requested,pulled); require(harmed,"cast safe"); }
}
