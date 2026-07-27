// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./PythStructs.sol";

interface IPyth {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getPrice(bytes32 id) external view returns (PythStructs.Price memory);
}
