// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Comptroller/ComptrollerInterfaces.sol";

// the whole point of this contract is to be able to call PBXAccrued() and claimPBXReward() in the same block for testing purposes
contract PBXRewardClaimer {
    ComptrollerNoNFTInterface comptroller;
    EIP20Interface PBXToken;

    event passed();
    event failure(uint a, uint b, string str);

    constructor(address _comptroller) public {
        comptroller = ComptrollerNoNFTInterface(_comptroller);
        PBXToken = EIP20Interface(comptroller.PBXToken());
    }

    function testClaimPBX(address holder, uint expectedReward) public {
        uint startingBalance = PBXToken.balanceOf(holder);
        uint PBXAccrued = comptroller.PBXAccrued(holder);
        comptroller.claimPBXReward(holder);
        uint PBXTransferred = PBXToken.balanceOf(holder) - startingBalance;

        if (PBXTransferred != expectedReward) {
            emit failure(PBXTransferred, expectedReward, "PBXTransferred != expectedReward");
            return;
        }

        if (PBXTransferred != PBXAccrued) {
            emit failure(PBXTransferred, PBXAccrued, "PBXTransferred != PBXAccrued");
            return;
        }

        if (comptroller.PBXAccrued(holder) != 0) {
            emit failure(comptroller.PBXAccrued(holder), 0, "comptroller.PBXAccrued(holder) != 0");
            return;
        }

        comptroller.claimPBXReward(holder);

        if (PBXToken.balanceOf(holder) != PBXAccrued + startingBalance) {
            emit failure(PBXToken.balanceOf(holder), PBXAccrued + startingBalance, "PBXToken.balanceOf(holder) != PBXAccrued + startingBalance");
            return;
        }

        emit passed();
    }
}
