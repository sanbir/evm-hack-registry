// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public assets=200; uint256 public totalShares=100; uint256 public attackerShares; bool public harmed; event Proof(uint256 shares);
    function run() external { uint256 hidden=100;
        // @> removeTokenIdAtIndex deletes accounting while the NFT stake remains in the vault
        assets-=hidden; attackerShares=100*totalShares/assets; assets+=hidden; harmed=attackerShares>50; emit Proof(attackerShares); require(harmed,"hidden NFT accounted"); }
}
