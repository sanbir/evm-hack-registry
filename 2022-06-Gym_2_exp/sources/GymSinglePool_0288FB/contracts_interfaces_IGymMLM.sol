// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

interface IGymMLM {
    function isOnGymMLM(address) external view returns (bool);

    function addGymMLM(address, uint256) external;

    function distributeRewards(
        uint256,
        address,
        address,
        uint32
    ) external;

    function updateInvestment(address _user, uint256 _newInvestment) external;

    function investment(address _user) external view returns (uint256);

    function getPendingRewards(address, uint32) external view returns (uint256);
}
