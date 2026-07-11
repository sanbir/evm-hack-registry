// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDistributor {
    function toggleOperator(address user, address operator) external;

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function operators(
        address user,
        address operator
    ) external view returns (uint256);
}
