// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IInvestor {
    function strategies(uint256) external view returns (address);
    function positions(uint256) external view returns (address, address, uint256, uint256, uint256, uint256, uint256);
    function life(uint256) external view returns (uint256);
    function earn(address, address, uint256, uint256, uint256, bytes calldata) external returns (uint256);
    function edit(uint256, int256, int256, bytes calldata) external;
    function kill(uint256, bytes calldata) external;
}
