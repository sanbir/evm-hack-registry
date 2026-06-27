// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IReferral {
    function caller() external view returns (address);

    function getRelationsREF(
        address _wallet
    ) external view returns (address[2] memory);

    function getUserInTeamByIndex(
        address _user,
        uint256 _index
    ) external view returns (address);

    function isSetted(address) external view returns (bool);

    function owner() external view returns (address);

    function referralLevel() external view returns (uint256);

    function relations(address, uint256) external view returns (address);

    function renounceOwnership() external;

    function updateSetted(address _address) external;

    function setReferral(address _from, address _to) external;

    function teamSize(address _user) external view returns (uint256);
}
