// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IAuction {
    function want() external view returns (address);

    function receiver() external view returns (address);

    function kick(address _token) external returns (uint256);
}
