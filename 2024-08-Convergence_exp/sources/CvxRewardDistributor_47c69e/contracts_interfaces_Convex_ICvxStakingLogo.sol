// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./../ICommonStruct.sol";

interface ICvxStakingLogo {
    struct LogoInfos {
        uint256 tokenId;
        string symbol;
        uint256 pending;
        uint256 totalStaked;
        uint256 cvgClaimable;
        ICommonStruct.TokenAmount[] cvxClaimable;
        uint256 unlockingTimestamp;
    }

    struct LogoInfosFull {
        uint256 tokenId;
        string symbol;
        uint256 pending;
        uint256 totalStaked;
        uint256 cvgClaimable;
        ICommonStruct.TokenAmount[] cvxClaimable;
        uint256 unlockingTimestamp;
        uint256 claimableInUsd;
        bool erroneousAmount;
        bool isLocked;
        uint256 hoursLock;
    }

    function _tokenURI(LogoInfos memory logoInfos) external pure returns (string memory output);

    function getLogoInfo(uint256 tokenId) external view returns (LogoInfosFull memory);
}
