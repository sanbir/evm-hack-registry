// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IGasUsage {
    function gasUsage(uint32 chainId) external view returns (uint256);
    function gasUsage(uint32 chainId, uint32 action) external view returns (uint256);

    function getTransactionFeeInNative(uint32 chainId) external view returns (uint256);
    function getTransactionFeeInNative(uint32 chainId, uint32 action) external view returns (uint256);

    function getTransactionFeeInStable(uint32 chainId) external view returns (uint256);
    function getTransactionFeeInStable(uint32 chainId, uint32 action) external view returns (uint256);
}
