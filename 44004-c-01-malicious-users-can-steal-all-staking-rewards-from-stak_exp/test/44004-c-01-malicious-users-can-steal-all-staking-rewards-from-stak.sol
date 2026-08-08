// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public pending=500; uint256 public credit; bool public harmed; event Proof(uint256 credit);
    function transfer(address,uint256) external { // @> reward crediting runs again even for a zero-value token transfer
        credit+=pending; }
    function run() external { this.transfer(address(1),0); this.transfer(address(1),0); this.transfer(address(1),0); this.transfer(address(1),0); harmed=credit>pending; emit Proof(credit); require(harmed,"reward stable"); }
}
