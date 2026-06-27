// SPDX-License-Identifier: ISC

pragma solidity 0.8.9;

contract RewardFeeProvider {
   function getClaimFee(uint256 lastClaimTime) public view returns(uint256) {
        uint256 dateDiff = (block.timestamp - lastClaimTime) / 1 days;
        if(dateDiff < 30) {
            dateDiff = 30 - dateDiff;
        } else {
            dateDiff = 0;
        }
        return dateDiff;
   }

   function caculateClaimFee(uint256 lastClaimTime, uint256 amount) public view returns(uint256) {
       return (getClaimFee(lastClaimTime) * amount) / 100;
   }
}
