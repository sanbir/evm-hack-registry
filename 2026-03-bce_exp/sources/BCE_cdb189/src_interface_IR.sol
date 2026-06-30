// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IR {
    struct Log {
        uint40 index;
        uint40 time;
        uint256 amountToken;
        uint256 amountUSDT;
        address account;
    }

    struct Postion {
        uint256 amountToken;
        uint256 amountUSDT;
        uint256 claimed;
        uint256 startTime;
        uint256 globalKpi;
    }

    function notifyBurn(address user, int256 amountBCE, int256 amountUSDT) external;

    function notifyLiquidity(address user, int256 amountUSDT) external;

    function globalKpiAcceleration(address user) external view returns (uint256);

    function calculateReward(address user) external view returns (uint256 reward);

    function getUserNode(address) external view returns (uint256);

    function claimReward(address) external;

    function notifyTransfer(address user, address inviter) external;
}
