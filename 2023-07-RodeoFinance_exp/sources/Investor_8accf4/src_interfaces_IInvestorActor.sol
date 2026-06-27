// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IInvestorActor {
    function life(uint256) external view returns (uint256);
    function edit(uint256, int256, int256, bytes calldata) external returns (int256, int256, int256);
    function kill(uint256, bytes calldata, address) external returns (uint256, uint256, uint256, uint256, uint256);
}
