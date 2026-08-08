// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public nonce; bool public harmed; event Proof(uint256 nonceAfter);
    function run() external { nonce=type(uint256).max;
        // @> uint256 nonce = ++s_batchNonce;
        unchecked { ++nonce; } harmed=nonce==0; emit Proof(nonce); require(harmed,"nonce did not wrap"); }
}
