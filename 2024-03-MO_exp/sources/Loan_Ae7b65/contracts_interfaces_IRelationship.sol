// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRelationship {
    function ROOT() external view returns (address);

    function hasBinded(address user) external view returns (bool);

    function referrers(address user) external view returns (address);
}
