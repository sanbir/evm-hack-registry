// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ISdtStakingLogo.sol";
import "./ISdtStakingPositionService.sol";

interface ISdtStakingPositionManager {
    struct ClaimSdtStakingContract {
        ISdtStakingPositionService stakingContract;
        uint256[] tokenIds;
    }

    function mint(address account) external;

    function burn(uint256 tokenId) external;

    function nextId() external view returns (uint256);

    function ownerOf(uint256 tokenId) external view returns (address);

    function checkMultipleClaimCompliance(ClaimSdtStakingContract[] calldata, address account) external view;

    function checkTokenFullCompliance(uint256 tokenId, address account) external view;

    function checkIncreaseDepositCompliance(uint256 tokenId, address account) external view;

    function stakingPerTokenId(uint256 tokenId) external view returns (address);

    function unlockingTimestampPerToken(uint256 tokenId) external view returns (uint256);

    function logoInfo(uint256 tokenId) external view returns (ISdtStakingLogo.LogoInfos memory);

    function getTokenIdsForWallet(address _wallet) external view returns (uint256[] memory);
}
