// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@rari-capital/solmate/src/tokens/ERC20.sol';

interface IBribe {
    function onVote(
        address user,
        uint256 newVote,
        uint256 originalTotalVotes
    ) external returns (uint256);

    function pendingTokens(address user) external view returns (uint256 pending);

    function rewardToken() external view returns (ERC20);
}
